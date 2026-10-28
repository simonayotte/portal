import AppKit
import Observation

struct Note: Identifiable, Hashable {
    let url: URL
    var modified: Date

    var id: URL { url }
    /// Like Obsidian, a note's title is its file name.
    var title: String { url.deletingPathExtension().lastPathComponent }
}

/// The notes of an Obsidian vault, read and written in place as plain `.md` files.
@MainActor @Observable
final class NoteStore {
    private(set) var vault: URL?
    /// Every note in the vault, most recently modified first.
    private(set) var notes: [Note] = []
    private(set) var selectedID: URL?
    private var content = ""

    private(set) var isDirty = false
    private(set) var canEdit = false
    private(set) var issue: NoteIssue?
    @ObservationIgnored private var baseline: Data?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var retryAction: (() -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Image files in the vault by lowercased file name, for `![[image.png]]` embeds.
    @ObservationIgnored private var imageFiles: [String: URL] = [:]
    /// Whether Obsidian is open; its own plugins then react to new notes. Replaceable for tests.
    @ObservationIgnored var isObsidianRunning: () -> Bool = { Obsidian.isRunning }
    /// Notes started in Portal; only these are renamed after their first line.
    @ObservationIgnored private var createdHere: Set<URL> = []

    private static let vaultKey = "vaultPath"
    private static let lastNoteKey = "lastNotePath"

    init(defaults: UserDefaults = .standard, restoreVault: Bool = true) {
        self.defaults = defaults
        guard restoreVault else { return }
        let saved = defaults.string(forKey: Self.vaultKey).map { URL(filePath: $0, directoryHint: .isDirectory) }
        if let vault = saved.flatMap({ FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }) ?? Obsidian.openVault() {
            open(vault: vault)
        }
    }

    var selected: Note? { notes.first { $0.id == selectedID } }

    /// Text of the selected note.
    var text: String {
        get { content }
        set {
            guard canEdit, newValue != content else { return }
            content = newValue
            scheduleSave()
        }
    }

    /// Folder of a note relative to the vault, or `nil` at the vault root.
    func folder(of note: Note) -> String? {
        guard let vault else { return nil }
        let folder = note.url.deletingLastPathComponent().standardizedFileURL.path
        let root = vault.standardizedFileURL.path
        return folder.count > root.count ? String(folder.dropFirst(root.count + 1)) : nil
    }

    // MARK: Vault

    func open(vault url: URL) {
        guard leaveCurrentNote() else { return }
        let scanned: (notes: [Note], images: [String: URL])
        do {
            scanned = try scan(url)
        } catch {
            report(error, at: url, kind: .read) { [weak self] in self?.open(vault: url) }
            return
        }
        vault = url.standardizedFileURL
        selectedID = nil
        content = ""
        baseline = nil
        canEdit = false
        notes = scanned.notes
        imageFiles = scanned.images
        createdHere.removeAll()
        defaults.set(url.path, forKey: Self.vaultKey)
        let last = defaults.string(forKey: Self.lastNoteKey).map { URL(filePath: $0).standardizedFileURL }
        if let last, notes.contains(where: { $0.id == last }) {
            load(last)
        } else if let recent = notes.first {
            load(recent.id)
        } else {
            create()
        }
    }

    /// Rescans the vault and reloads the open note if it changed on disk (e.g. edited in Obsidian).
    @discardableResult
    func refresh() -> Bool {
        guard let vault else { return false }
        do {
            let scanned = try scan(vault)
            var found = scanned.notes
            imageFiles = scanned.images
            // Keep the buffer addressable even if another app removed its file.
            if let selected, !found.contains(where: { $0.id == selected.id }) {
                found.insert(selected, at: 0)
            }
            notes = found
            reloadIfChangedOnDisk()
            return true
        } catch {
            report(error, at: vault, kind: .read) { [weak self] in self?.refresh() }
            return false
        }
    }

    private func scan(_ vault: URL) throws -> (notes: [Note], images: [String: URL]) {
        _ = try FileManager.default.contentsOfDirectory(at: vault, includingPropertiesForKeys: nil)
        var scanError: Error?
        guard let files = FileManager.default.enumerator(
            at: vault,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in scanError = error; return false }
        ) else { throw CocoaError(.fileReadUnknown) }
        var notes: [Note] = []
        var images: [String: URL] = [:]
        for case let url as URL in files {
            let fileExtension = url.pathExtension.lowercased()
            if fileExtension == "md" {
                notes.append(Note(url: url.standardizedFileURL, modified: Self.modificationDate(url) ?? .distantPast))
            } else if ImageEmbed.imageExtensions.contains(fileExtension) {
                images[url.lastPathComponent.lowercased()] = url.standardizedFileURL
            }
        }
        if let scanError { throw scanError }
        return (notes.sorted { $0.modified > $1.modified }, images)
    }

    @discardableResult
    private func reloadIfChangedOnDisk() -> Bool {
        guard let note = selected, !isDirty, baseline != nil else { return false }
        do {
            let data = try NotePersistence.read(note.url)
            guard data != baseline else { return false }
            content = try NotePersistence.text(data)
            baseline = data
            clearIssue()
            return true
        } catch {
            report(error, at: note.url, kind: .read) { [weak self] in self?.reloadCurrentNote() }
            return false
        }
    }

    // MARK: Notes

    func select(_ id: URL?) {
        guard let id, id != selectedID else { return }
        guard leaveCurrentNote() else { return }
        load(id)
    }

    /// Opens the note a `[[wikilink]]` points to, creating it when it does not exist (like Obsidian).
    func open(link: String) {
        let target = String(link.split(separator: "#", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        let match = notes.first { note in
            let path = [folder(of: note), note.title].compactMap(\.self).joined(separator: "/")
            return path.caseInsensitiveCompare(target) == .orderedSame || note.title.caseInsensitiveCompare(target) == .orderedSame
        }
        if let match { select(match.id) } else { create(named: target) }
    }

    /// Starts a note where Obsidian puts new notes. It is written to disk on the first edit.
    func create(named requested: String? = nil) {
        guard let vault else { return }
        guard leaveCurrentNote() else { return }
        let folder = Obsidian.newNoteFolder(in: vault, current: selected?.url)
        let base = requested.flatMap(Self.fileName) ?? "Untitled"
        var name = base
        var suffix = 0
        while FileManager.default.fileExists(atPath: folder.appending(path: name + ".md").path) {
            suffix += 1
            name = "\(base) \(suffix)"
        }
        let url = folder.appending(path: name + ".md").standardizedFileURL
        notes.insert(Note(url: url, modified: .now), at: 0)
        createdHere.insert(url)
        content = ""
        baseline = nil
        isDirty = false
        canEdit = true
        clearIssue()
        selectedID = url
        defaults.set(url.path, forKey: Self.lastNoteKey)
    }

    /// Saves the open note. A note started in Portal and still called "Untitled" is renamed
    /// after its first line, or forgotten if it was never written.
    @discardableResult
    func leaveCurrentNote() -> Bool {
        guard flush() else { return false }
        guard let note = selected, createdHere.contains(note.id), note.title.wholeMatch(of: /Untitled( \d+)?/) != nil else { return true }
        guard let baseline else {
            notes.removeAll { $0.id == note.id }
            createdHere.remove(note.id)
            selectedID = nil
            canEdit = false
            return true
        }
        guard let name = Self.firstLineName(content) else { return true }
        let target = note.url.deletingLastPathComponent().appending(path: name + ".md").standardizedFileURL
        guard target != note.url else { return true }
        do {
            guard try NotePersistence.rename(note.url, to: target, baseline: baseline) else { return true }
        } catch {
            isDirty = true
            report(error, at: note.url, kind: .save) { [weak self] in self?.leaveCurrentNote() }
            return false
        }
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = Note(url: target, modified: notes[index].modified)
        }
        selectedID = target
        createdHere.remove(note.id)
        createdHere.insert(target)
        defaults.set(target.path, forKey: Self.lastNoteKey)
        return true
    }

    private func load(_ id: URL) {
        do {
            let data = try NotePersistence.read(id)
            let text = try NotePersistence.text(data)
            content = text
            baseline = data
            isDirty = false
            canEdit = true
            selectedID = id
            defaults.set(id.path, forKey: Self.lastNoteKey)
            clearIssue()
        } catch {
            report(error, at: id, kind: .read) { [weak self] in self?.selectAfterSaving(id) }
        }
    }

    private func selectAfterSaving(_ id: URL) {
        guard leaveCurrentNote() else { return }
        load(id)
    }

    /// Opens today's daily note, creating it from the daily note template like Obsidian's Daily Notes plugin.
    func openDailyNote(on date: Date = .now) {
        // Nothing else (especially rollover deletion) may run until this buffer is safe.
        guard let vault, leaveCurrentNote() else { return }
        let settings = Obsidian.dailyNoteSettings(in: vault)
        let name = Obsidian.format(date, settings.format)
        let url = vault.appending(path: settings.folder, directoryHint: .isDirectory)
            .appending(path: name + ".md").standardizedFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            var template = ""
            if let path = settings.template {
                let file = vault.appending(path: path.hasSuffix(".md") ? path : path + ".md")
                do {
                    template = try NotePersistence.text(NotePersistence.read(file))
                } catch {
                    report(error, at: file, kind: .read) { [weak self] in self?.openDailyNote(on: date) }
                    return
                }
            }
            var text = Obsidian.fillTemplate(template, title: name, date: date, dateFormat: settings.format)
            // Roll unfinished todos over like the Rollover Daily Todos plugin. When Obsidian is open the plugin
            // does it itself as soon as it sees the new note, so Portal only picks up its edit.
            let rollover = Obsidian.rolloverSettings(in: vault).flatMap { $0.rolloverOnFileCreate ? $0 : nil }
            let pluginRollsOver = rollover != nil && isObsidianRunning()
            var removal: RolloverRemoval?
            if let rollover, !pluginRollsOver, let previous = previousDailyNote(before: date, settings: settings) {
                do {
                    (text, removal) = try roll(from: previous, into: text, settings: rollover, destination: url)
                } catch {
                    report(error, at: previous, kind: .read) { [weak self] in self?.openDailyNote(on: date) }
                    return
                }
            }
            // Keep even a failed daily-note write available for Save a Copy.
            if !notes.contains(where: { $0.id == url }) {
                notes.insert(Note(url: url, modified: .now), at: 0)
            }
            selectedID = url
            content = text
            baseline = nil
            canEdit = true
            isDirty = true
            defaults.set(url.path, forKey: Self.lastNoteKey)
            guard flush() else { return }
            // Copy first, delete second: a failure can duplicate todos, never lose them.
            if let removal { completeRollover(removal) }
            if pluginRollsOver { reloadAfterExternalEdit(of: url) }
            return
        }
        if !notes.contains(where: { $0.id == url }) {
            notes.insert(Note(url: url, modified: .now), at: 0)
        }
        load(url)
    }

    /// The most recent daily note before `date`.
    private func previousDailyNote(before date: Date, settings: Obsidian.DailyNoteSettings) -> URL? {
        guard let vault else { return nil }
        let folder = vault.appending(path: settings.folder, directoryHint: .isDirectory).standardizedFileURL.path + "/"
        let today = Calendar.current.startOfDay(for: date)
        let dailyNotes = notes.compactMap { note -> (url: URL, day: Date)? in
            let path = note.url.deletingPathExtension().path
            guard path.hasPrefix(folder), let day = Obsidian.date(from: String(path.dropFirst(folder.count)), format: settings.format),
                  day < today else { return nil }
            return (note.url, day)
        }
        return dailyNotes.max { $0.day < $1.day }?.url
    }

    /// Copies the previous daily note's unfinished todos into `text`, as the Rollover Daily Todos plugin does.
    private struct RolloverRemoval {
        let url: URL
        let baseline: Data
        let updated: Data
        let destination: URL
        let savedCopy: Data
    }

    private func roll(from previous: URL, into text: String, settings: Obsidian.RolloverSettings, destination: URL) throws -> (String, RolloverRemoval?) {
        let data = try NotePersistence.read(previous)
        let previousText = try NotePersistence.text(data)
        let found = Obsidian.unfinishedTodos(in: previousText, settings: settings)
        let todos = settings.removeEmptyTodos
            ? found.filter { !["- [ ]", "- [  ]"].contains($0.trimmingCharacters(in: .whitespaces)) }
            : found
        guard !todos.isEmpty else { return (text, nil) }

        let block = "\n" + todos.joined(separator: "\n")
        var result = text + block
        if settings.templateHeading != "none", let heading = text.range(of: settings.templateHeading) {
            result = text.replacingCharacters(in: heading, with: settings.templateHeading + block)
        }
        var removal: RolloverRemoval?
        if settings.deleteOnComplete {
            let kept = previousText.split(separator: "\n", omittingEmptySubsequences: false).filter { !found.contains(String($0)) }
            removal = RolloverRemoval(url: previous, baseline: data, updated: Data(kept.joined(separator: "\n").utf8),
                                      destination: destination, savedCopy: Data(result.utf8))
        }
        return (result, removal)
    }

    private func completeRollover(_ removal: RolloverRemoval) {
        do {
            try NotePersistence.removeRolledTodos(removal.updated, from: removal.url, baseline: removal.baseline,
                                                 copiedTo: removal.destination, savedCopy: removal.savedCopy)
            clearIssue()
        } catch {
            report(error, at: removal.url, kind: .save) { [weak self] in self?.completeRollover(removal) }
        }
    }

    /// Reloads `url` once something else edits it, for a few seconds, unless you have started typing.
    private func reloadAfterExternalEdit(of url: URL) {
        Task { [weak self] in
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.selectedID == url, !self.isDirty else { return }
                if self.reloadIfChangedOnDisk() { return }
            }
        }
    }

    // MARK: Images

    /// File an image embed points to: `![](path)` relative to the note or the vault,
    /// `![[name]]` by vault path or, like Obsidian, by file name anywhere in the vault.
    func resolveImage(_ embed: ImageEmbed) -> URL? {
        guard let vault else { return nil }
        if let url = URL(string: embed.source), let scheme = url.scheme {
            return scheme == "file" ? url : nil
        }
        let path = embed.source.removingPercentEncoding ?? embed.source
        var candidates = [vault.appending(path: path)]
        if !embed.isWikilink, let folder = selected?.url.deletingLastPathComponent() {
            candidates.insert(folder.appending(path: path), at: 0)
        }
        let found = candidates.map(\.standardizedFileURL).first { FileManager.default.fileExists(atPath: $0.path) }
        return found ?? imageFiles[(path as NSString).lastPathComponent.lowercased()]
    }

    /// Saves a pasted image where Obsidian puts attachments and returns the embed to insert.
    func saveImage(_ data: Data, fileExtension: String) -> String? {
        guard let vault else { return nil }
        let folder = Obsidian.attachmentFolder(in: vault, note: selected?.url)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let base = "Pasted image \(formatter.string(from: .now))"
        var name = "\(base).\(fileExtension)"
        var suffix = 0
        while FileManager.default.fileExists(atPath: folder.appending(path: name).path) {
            suffix += 1
            name = "\(base) \(suffix).\(fileExtension)"
        }
        let url = folder.appending(path: name).standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            return nil
        }
        imageFiles[name.lowercased()] = url
        return "![[\(name)]]"
    }

    // MARK: Saving

    @discardableResult
    func flush() -> Bool {
        saveTask?.cancel()
        guard isDirty else { return true }
        guard let note = selected else { return false }
        let data = Data(content.utf8)
        do {
            try NotePersistence.write(data, to: note.url, baseline: baseline)
            baseline = data
            isDirty = false
            clearIssue()
            if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index].modified = .now }
            return true
        } catch {
            report(error, at: note.url, kind: .save) { [weak self] in self?.flush() }
            return false
        }
    }

    var canRetry: Bool { retryAction != nil }

    func retry() { retryAction?() }

    /// The caller must confirm discarding edits. A failed read never changes the buffer.
    func reloadCurrentNote(discardChanges: Bool = false) {
        guard let selectedID, !isDirty || discardChanges else { return }
        saveTask?.cancel()
        load(selectedID)
    }

    /// Switches to the saved copy only after its exclusive creation succeeds.
    @discardableResult
    func saveCopy(to url: URL) -> Bool {
        guard canEdit else { return false }
        saveTask?.cancel()
        let data = Data(content.utf8)
        do {
            let copy = try NotePersistence.saveCopy(data, to: url.standardizedFileURL)
            if let selected, baseline == nil, !FileManager.default.fileExists(atPath: selected.url.path) {
                notes.removeAll { $0.id == selected.id }
            }
            notes.insert(Note(url: copy, modified: .now), at: 0)
            selectedID = copy
            baseline = data
            isDirty = false
            defaults.set(copy.path, forKey: Self.lastNoteKey)
            clearIssue()
            return true
        } catch {
            report(error, at: url, kind: .save) { [weak self] in self?.saveCopy(to: url) }
            return false
        }
    }

    private func report(_ error: Error, at url: URL, kind: NoteIssue.Kind, retry: (() -> Void)? = nil) {
        issue = NoteIssue(kind: (error as? NoteFileError) == .conflict ? .conflict : kind, url: url, message: error.localizedDescription)
        retryAction = retry
    }

    private func clearIssue() {
        issue = nil
        retryAction = nil
    }

    private func scheduleSave() {
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { self?.flush() }
        }
    }

    // MARK: Helpers

    private static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// File name for a note titled by the first line of `text`, skipping front matter and Markdown syntax.
    private static func firstLineName(_ text: String) -> String? {
        let body = text.replacing(/\A---\n[\s\S]*?\n---[ \t]*(\n|\z)/, with: "")
        guard let line = body.split(separator: "\n").first(where: { !$0.allSatisfy(\.isWhitespace) }) else { return nil }
        let plain = line
            .replacing(/^\s*(#{1,6}\s+|[-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+|>\s*)/, with: "")
            .replacing(/\*\*|__|~~|`|\[\[|\]\]/, with: "")
        return fileName(String(plain))
    }

    /// Makes `title` safe as an Obsidian file name.
    private static func fileName(_ title: String) -> String? {
        let cleaned = title
            .replacing(/[\\\/:*?"<>|#^\[\]]/, with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let name = String(cleaned.prefix(100)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name.hasPrefix(".") || name.allSatisfy({ $0 == "-" }) ? nil : name
    }
}

/// Reads Obsidian's own settings.
enum Obsidian {
    private struct Config: Decodable {
        struct Vault: Decodable {
            let path: String
            let ts: Double?
            let open: Bool?
        }

        let vaults: [String: Vault]
    }

    private struct AppSettings: Decodable {
        let newFileLocation: String?
        let newFileFolderPath: String?
        let attachmentFolderPath: String?
    }

    private static func settings(in vault: URL) -> AppSettings? {
        (try? Data(contentsOf: vault.appending(path: ".obsidian/app.json")))
            .flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
    }

    struct DailyNoteSettings {
        var folder = ""
        /// Moment.js date format used for the file name.
        var format = "YYYY-MM-DD"
        /// Vault path of the template, without `.md`.
        var template: String?
    }

    private struct DailyNotesConfig: Decodable {
        let folder: String?
        let format: String?
        let template: String?
    }

    /// Settings of Obsidian's Daily Notes plugin, with its defaults for anything not set.
    static func dailyNoteSettings(in vault: URL) -> DailyNoteSettings {
        let config = (try? Data(contentsOf: vault.appending(path: ".obsidian/daily-notes.json")))
            .flatMap { try? JSONDecoder().decode(DailyNotesConfig.self, from: $0) }
        var settings = DailyNoteSettings()
        if let folder = config?.folder { settings.folder = folder }
        if let format = config?.format, !format.isEmpty { settings.format = format }
        if let template = config?.template, !template.isEmpty { settings.template = template }
        return settings
    }

    /// Fills Obsidian template variables: `{{title}}`, `{{date}}`, `{{time}}`, `{{yesterday}}`,
    /// `{{tomorrow}}`, each optionally with a format like `{{date:dddd}}`.
    static func fillTemplate(_ template: String, title: String, date: Date, dateFormat: String) -> String {
        template.replacing(/\{\{\s*(title|date|time|yesterday|tomorrow)\s*(?::([^}]*))?\}\}/) { match in
            let format = match.2.map { String($0).trimmingCharacters(in: .whitespaces) }
            let day: TimeInterval = 24 * 60 * 60
            return switch match.1 {
            case "title": title
            case "time": Self.format(date, format ?? "HH:mm")
            case "yesterday": Self.format(date.addingTimeInterval(-day), format ?? dateFormat)
            case "tomorrow": Self.format(date.addingTimeInterval(day), format ?? dateFormat)
            default: Self.format(date, format ?? dateFormat)
            }
        }
    }

    /// Formats `date` with a Moment.js format string, as Obsidian does (common tokens only).
    static func format(_ date: Date, _ moment: String) -> String {
        dateFormatter(moment).string(from: date)
    }

    /// Parses `string` strictly with a Moment.js format; `nil` unless it round-trips exactly.
    static func date(from string: String, format moment: String) -> Date? {
        let formatter = dateFormatter(moment)
        guard let date = formatter.date(from: string), formatter.string(from: date) == string else { return nil }
        return date
    }

    private static func dateFormatter(_ moment: String) -> DateFormatter {
        let tokens: [String: String] = [
            "YYYY": "yyyy", "YY": "yy", "MMMM": "MMMM", "MMM": "MMM", "MM": "MM", "M": "M",
            "DD": "dd", "D": "d", "dddd": "EEEE", "ddd": "EEE", "HH": "HH", "H": "H",
            "hh": "hh", "h": "h", "mm": "mm", "m": "m", "ss": "ss", "s": "s", "A": "a", "a": "a",
        ]
        var pattern = ""
        for match in moment.matches(of: /\[[^\]]*\]|YYYY|YY|MMMM|MMM|MM|M|DD|D|dddd|ddd|HH|H|hh|h|mm|m|ss|s|A|a|./) {
            let token = String(match.output)
            if token.hasPrefix("[") {
                pattern += "'" + token.dropFirst().dropLast().replacing("'", with: "''") + "'"
            } else if let mapped = tokens[token] {
                pattern += mapped
            } else if token.first?.isLetter == true {
                pattern += "'" + token + "'"
            } else {
                pattern += token == "'" ? "''" : token
            }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter
    }

    @MainActor static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "md.obsidian" }
    }

    /// Settings of the Rollover Daily Todos community plugin, or `nil` when it is not enabled.
    struct RolloverSettings: Decodable {
        var templateHeading = "none"
        var deleteOnComplete = false
        var removeEmptyTodos = false
        var rolloverChildren = false
        var rolloverOnFileCreate = true
        var doneStatusMarkers = "xX-"

        private enum CodingKeys: String, CodingKey {
            case templateHeading, deleteOnComplete, removeEmptyTodos, rolloverChildren, rolloverOnFileCreate, doneStatusMarkers
        }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            templateHeading = try values.decodeIfPresent(String.self, forKey: .templateHeading) ?? templateHeading
            deleteOnComplete = try values.decodeIfPresent(Bool.self, forKey: .deleteOnComplete) ?? deleteOnComplete
            removeEmptyTodos = try values.decodeIfPresent(Bool.self, forKey: .removeEmptyTodos) ?? removeEmptyTodos
            rolloverChildren = try values.decodeIfPresent(Bool.self, forKey: .rolloverChildren) ?? rolloverChildren
            rolloverOnFileCreate = try values.decodeIfPresent(Bool.self, forKey: .rolloverOnFileCreate) ?? rolloverOnFileCreate
            doneStatusMarkers = try values.decodeIfPresent(String.self, forKey: .doneStatusMarkers) ?? doneStatusMarkers
        }
    }

    static func rolloverSettings(in vault: URL) -> RolloverSettings? {
        let id = "obsidian-rollover-daily-todos"
        let enabled = (try? Data(contentsOf: vault.appending(path: ".obsidian/community-plugins.json")))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        guard enabled.contains(id) else { return nil }
        let data = try? Data(contentsOf: vault.appending(path: ".obsidian/plugins/\(id)/data.json"))
        return data.flatMap { try? JSONDecoder().decode(RolloverSettings.self, from: $0) } ?? RolloverSettings()
    }

    /// Unfinished todos (`- [ ]`, or any status not in the done markers), with their nested lines when
    /// `rolloverChildren` is on — the same rules as the plugin.
    static func unfinishedTodos(in text: String, settings: RolloverSettings) -> [String] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        func indentation(_ line: String) -> Int {
            line.firstIndex { !$0.isWhitespace }.map { line.distance(from: line.startIndex, to: $0) } ?? -1
        }
        func isTodo(_ line: String) -> Bool {
            guard let status = line.firstMatch(of: /\s*[*+-] \[(.+?)\]/)?.1, status.count == 1,
                  !status.unicodeScalars.contains(where: { ["\u{202E}", "\u{200B}", "\u{200C}", "\u{200D}"].contains($0) })
            else { return false }
            return !status.contains { settings.doneStatusMarkers.contains($0) }
        }

        var todos: [String] = []
        var index = 0
        while index < lines.count {
            if isTodo(lines[index]) {
                todos.append(lines[index])
                if settings.rolloverChildren {
                    var child = index + 1
                    while child < lines.count, indentation(lines[child]) > indentation(lines[index]) {
                        todos.append(lines[child])
                        child += 1
                    }
                    index = child - 1
                }
            }
            index += 1
        }
        return todos
    }

    /// The vault Obsidian has open, or the one it opened most recently.
    static func openVault() -> URL? {
        let config = URL.applicationSupportDirectory.appending(path: "obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: config),
              let vaults = try? JSONDecoder().decode(Config.self, from: data).vaults.values else { return nil }
        let vault = vaults.max { ($0.open == true ? 1 : 0, $0.ts ?? 0) < ($1.open == true ? 1 : 0, $1.ts ?? 0) }
        return vault.map { URL(filePath: $0.path, directoryHint: .isDirectory) }
    }

    /// Folder for new notes per Obsidian's "Default location for new notes" setting.
    static func newNoteFolder(in vault: URL, current: URL?) -> URL {
        let settings = settings(in: vault)
        switch settings?.newFileLocation {
        case "current":
            return current?.deletingLastPathComponent() ?? vault
        case "folder":
            return vault.appending(path: settings?.newFileFolderPath ?? "", directoryHint: .isDirectory)
        default:
            return vault
        }
    }

    /// Folder for pasted images per Obsidian's "Default location for new attachments" setting.
    static func attachmentFolder(in vault: URL, note: URL?) -> URL {
        let path = settings(in: vault)?.attachmentFolderPath ?? "/"
        let noteFolder = note?.deletingLastPathComponent() ?? vault
        if path.isEmpty || path == "/" { return vault }
        if path == "./" || path == "." { return noteFolder }
        if path.hasPrefix("./") { return noteFolder.appending(path: String(path.dropFirst(2)), directoryHint: .isDirectory) }
        return vault.appending(path: path, directoryHint: .isDirectory)
    }
}
