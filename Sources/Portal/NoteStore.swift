import Foundation
import Observation

struct Note: Identifiable, Hashable {
    let url: URL
    var text: String
    var modified: Date

    var id: URL { url }

    var title: String {
        let firstLine = text.split(separator: "\n").first ?? ""
        let title = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces))
        return title.isEmpty ? "Untitled" : title
    }
}

/// Notes are plain `.md` files in ~/Library/Application Support/Portal.
@MainActor @Observable
final class NoteStore {
    private(set) var notes: [Note] = []
    private(set) var selectedID: URL?

    @ObservationIgnored private let directory = URL.applicationSupportDirectory
        .appending(path: "Portal", directoryHint: .isDirectory)
    @ObservationIgnored private var pending: Note?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
        if notes.isEmpty { create() } else { selectedID = notes.first?.id }
    }

    var selected: Note? { notes.first { $0.id == selectedID } }

    var text: String {
        get { selected?.text ?? "" }
        set {
            guard let index = notes.firstIndex(where: { $0.id == selectedID }) else { return }
            notes[index].text = newValue
            notes[index].modified = .now
            scheduleSave(notes[index])
        }
    }

    func select(_ id: URL?) {
        flush()
        selectedID = id
    }

    func create() {
        let url = directory.appending(path: "\(UUID().uuidString).md")
        notes.insert(Note(url: url, text: "", modified: .now), at: 0)
        select(url)
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        if pending?.id == id { pending = nil }
        try? FileManager.default.trashItem(at: id, resultingItemURL: nil)
        notes.removeAll { $0.id == id }
        if notes.isEmpty { create() } else { select(notes.first?.id) }
    }

    func flush() {
        saveTask?.cancel()
        guard let note = pending else { return }
        pending = nil
        try? note.text.write(to: note.url, atomically: true, encoding: .utf8)
    }

    private func load() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        notes = urls
            .filter { $0.pathExtension == "md" }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate
                return Note(url: url, text: text, modified: modified ?? .distantPast)
            }
            .sorted { $0.modified > $1.modified }
    }

    private func scheduleSave(_ note: Note) {
        pending = note
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { self?.flush() }
        }
    }
}
