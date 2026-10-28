import Foundation
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

    @ObservationIgnored private var isDirty = false
    @ObservationIgnored private var loadedModified: Date?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Notes started in Portal; only these are renamed after their first line.
    @ObservationIgnored private var createdHere: Set<URL> = []

    private static let vaultKey = "vaultPath"
    private static let lastNoteKey = "lastNotePath"

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.vaultKey).map { URL(filePath: $0, directoryHint: .isDirectory) }
        if let vault = saved.flatMap({ FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }) ?? Obsidian.openVault() {
            open(vault: vault)
        }
    }

    var selected: Note? { notes.first { $0.id == selectedID } }

    /// Text of the selected note.
    var text: String {
        get { content }
        set {
            guard newValue != content else { return }
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
        leaveCurrentNote()
        vault = url.standardizedFileURL
        selectedID = nil
        UserDefaults.standard.set(url.path, forKey: Self.vaultKey)
        refresh()
        let last = UserDefaults.standard.string(forKey: Self.lastNoteKey).map { URL(filePath: $0).standardizedFileURL }
        if let last, notes.contains(where: { $0.id == last }) {
            load(last)
        } else if let recent = notes.first {
            load(recent.id)
        } else {
            create()
        }
    }

    /// Rescans the vault and reloads the open note if it changed on disk (e.g. edited in Obsidian).
    func refresh() {
        guard let vault else { return }
        var found = scan(vault)
        // Keep a new note that has not been written yet.
        if let selected, !found.contains(where: { $0.id == selected.id }), !FileManager.default.fileExists(atPath: selected.url.path) {
            found.insert(selected, at: 0)
        }
        notes = found
        reloadIfChangedOnDisk()
    }

    private func scan(_ vault: URL) -> [Note] {
        guard let files = FileManager.default.enumerator(
            at: vault,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return files
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "md" }
            .map { Note(url: $0.standardizedFileURL, modified: Self.modificationDate($0) ?? .distantPast) }
            .sorted { $0.modified > $1.modified }
    }

    private func reloadIfChangedOnDisk() {
        guard let note = selected, !isDirty,
              let modified = Self.modificationDate(note.url), modified != loadedModified,
              let text = try? String(contentsOf: note.url, encoding: .utf8) else { return }
        content = text
        loadedModified = modified
    }

    // MARK: Notes

    func select(_ id: URL?) {
        guard let id, id != selectedID else { return }
        leaveCurrentNote()
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
        leaveCurrentNote()
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
        loadedModified = nil
        isDirty = false
        selectedID = url
        UserDefaults.standard.set(url.path, forKey: Self.lastNoteKey)
    }

    /// Saves the open note. A note started in Portal and still called "Untitled" is renamed
    /// after its first line, or forgotten if it was never written.
    func leaveCurrentNote() {
        flush()
        guard let note = selected, createdHere.contains(note.id), note.title.wholeMatch(of: /Untitled( \d+)?/) != nil else { return }
        guard FileManager.default.fileExists(atPath: note.url.path) else {
            notes.removeAll { $0.id == note.id }
            return
        }
        guard let name = Self.firstLineName(content) else { return }
        let target = note.url.deletingLastPathComponent().appending(path: name + ".md").standardizedFileURL
        guard !FileManager.default.fileExists(atPath: target.path),
              (try? FileManager.default.moveItem(at: note.url, to: target)) != nil else { return }
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = Note(url: target, modified: notes[index].modified)
        }
        selectedID = target
        UserDefaults.standard.set(target.path, forKey: Self.lastNoteKey)
    }

    private func load(_ id: URL) {
        content = (try? String(contentsOf: id, encoding: .utf8)) ?? ""
        loadedModified = Self.modificationDate(id)
        isDirty = false
        selectedID = id
        UserDefaults.standard.set(id.path, forKey: Self.lastNoteKey)
    }

    // MARK: Saving

    func flush() {
        saveTask?.cancel()
        guard isDirty, let note = selected else { return }
        isDirty = false
        try? FileManager.default.createDirectory(at: note.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? content.write(to: note.url, atomically: true, encoding: .utf8)
        loadedModified = Self.modificationDate(note.url)
        if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index].modified = .now }
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
        let settings = (try? Data(contentsOf: vault.appending(path: ".obsidian/app.json")))
            .flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
        switch settings?.newFileLocation {
        case "current":
            return current?.deletingLastPathComponent() ?? vault
        case "folder":
            return vault.appending(path: settings?.newFileFolderPath ?? "", directoryHint: .isDirectory)
        default:
            return vault
        }
    }
}
