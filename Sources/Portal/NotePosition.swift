import AppKit

/// Native text positions use UTF-16 offsets, just like NSTextView.
struct NotePosition: Codable, Equatable {
    var selection: NSRange
    var scrollOrigin: NSPoint
    var vim: VimEngine.SelectionState

    func clamped(toUTF16Length length: Int) -> Self {
        var result = self
        let end = max(0, length)
        result.selection.location = min(max(0, selection.location), end)
        result.selection.length = min(max(0, selection.length), end - result.selection.location)
        result.vim.cursor = min(max(0, vim.cursor), end)
        result.vim.anchor = min(max(0, vim.anchor), end)
        result.scrollOrigin.x = scrollOrigin.x.isFinite ? max(0, scrollOrigin.x) : 0
        result.scrollOrigin.y = scrollOrigin.y.isFinite ? max(0, scrollOrigin.y) : 0
        return result
    }
}

/// A bounded, most-recently-used history, separate from vault contents and note persistence.
@MainActor
final class NotePositionStore {
    static let shared = NotePositionStore()
    static let defaultsKey = "note-reading-positions-v1"

    private struct Entry: Codable {
        var noteID: String
        var position: NotePosition
    }

    private let defaults: UserDefaults
    private let capacity: Int
    private var entries: [Entry]

    init(defaults: UserDefaults = .standard, capacity: Int = 200) {
        self.defaults = defaults
        self.capacity = max(1, capacity)
        let saved = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        entries = Array(saved.suffix(self.capacity))
    }

    func position(for noteID: URL) -> NotePosition? {
        entries.last { $0.noteID == noteID.standardizedFileURL.absoluteString }?.position
    }

    func save(_ position: NotePosition, for noteID: URL) {
        let key = noteID.standardizedFileURL.absoluteString
        guard entries.last?.noteID != key || entries.last?.position != position else { return }
        entries.removeAll { $0.noteID == key }
        entries.append(Entry(noteID: key, position: position))
        entries = Array(entries.suffix(capacity))
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// SwiftUI gives the scroll view its real viewport after makeNSView returns.
final class PositionRestoringScrollView: NSScrollView {
    var didLayout: (() -> Void)?

    override func layout() {
        super.layout()
        didLayout?()
    }
}
