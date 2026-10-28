import Foundation
import Observation

/// Navigation metadata is independent of file modification dates and note saving.
@MainActor @Observable
final class NoteNavigation {
    private(set) var pinned: [String]
    private(set) var recent: [String]

    static let historyLimit = 100
    private static let pinnedKey = "pinnedNoteURLs"
    private static let recentKey = "recentNoteURLs"
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pinned = Self.restored(defaults.stringArray(forKey: Self.pinnedKey) ?? [])
        recent = Array(Self.restored(defaults.stringArray(forKey: Self.recentKey) ?? []).prefix(Self.historyLimit))
    }

    static func identity(_ url: URL) -> String { url.standardizedFileURL.absoluteString }

    func isPinned(_ url: URL) -> Bool { pinned.contains(Self.identity(url)) }

    func togglePin(_ url: URL) {
        let id = Self.identity(url)
        if pinned.contains(id) { pinned.removeAll { $0 == id } }
        else { pinned.insert(id, at: 0) }
        defaults.set(pinned, forKey: Self.pinnedKey)
    }

    func recordOpened(_ url: URL) {
        let id = Self.identity(url)
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        recent = Array(recent.prefix(Self.historyLimit))
        defaults.set(recent, forKey: Self.recentKey)
    }

    /// Pins in pin order, then opened recency, then the existing modified-date
    /// fallback. Canonical URLs break ties and suppress duplicate file identities.
    func ordered(_ notes: [Note]) -> [Note] {
        let fallback = notes.sorted {
            $0.modified == $1.modified ? Self.identity($0.id) < Self.identity($1.id) : $0.modified > $1.modified
        }
        var byID: [String: Note] = [:]
        for note in fallback where byID[Self.identity(note.id)] == nil {
            byID[Self.identity(note.id)] = note
        }
        return (pinned + recent + fallback.map { Self.identity($0.id) }).compactMap { byID.removeValue(forKey: $0) }
    }

    private static func restored(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let url = URL(string: value), url.isFileURL else { return nil }
            let id = identity(url)
            return seen.insert(id).inserted ? id : nil
        }
    }
}
