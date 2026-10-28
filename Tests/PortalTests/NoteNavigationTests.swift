import Foundation
import Testing
@testable import Portal

@MainActor
struct NoteNavigationTests {
    @Test func ordersPinsThenOpenedRecencyThenRemainingNotes() throws {
        try withNavigation { navigation, _ in
            let a = note("A.md", modified: 10)
            let b = note("B.md", modified: 100)
            let c = note("C.md", modified: 20)
            let d = note("D.md", modified: 200)
            let e = note("E.md", modified: 300)
            navigation.togglePin(c.id)
            navigation.togglePin(a.id)
            navigation.recordOpened(d.id)
            navigation.recordOpened(c.id)
            navigation.recordOpened(b.id)

            #expect(navigation.ordered([e, d, b, c, a]).map(\.title) == ["A", "C", "B", "D", "E"])
            navigation.togglePin(a.id)
            #expect(navigation.ordered([a, b, c, d, e]).map(\.title) == ["C", "B", "D", "E", "A"])
        }
    }

    @Test func persistsPinsAndRecencyWithoutTreatingPinsAsOpens() throws {
        try withNavigation { navigation, defaults in
            let a = note("A.md")
            let b = note("B.md")
            navigation.togglePin(a.id)
            #expect(navigation.recent.isEmpty)
            navigation.recordOpened(a.id)
            navigation.recordOpened(b.id)
            navigation.recordOpened(a.id)

            let restored = NoteNavigation(defaults: defaults)
            #expect(restored.isPinned(a.id))
            #expect(restored.recent == [a.id, b.id].map(NoteNavigation.identity))
            restored.togglePin(a.id)
            #expect(NoteNavigation(defaults: defaults).pinned.isEmpty)
        }
    }

    @Test func standardizesAndDeduplicatesFileIdentities() throws {
        try withNavigation { navigation, defaults in
            let a = note("A.md")
            let alias = note("folder/../A.md")
            navigation.togglePin(alias.id)
            #expect(navigation.isPinned(a.id))
            navigation.recordOpened(a.id)
            navigation.recordOpened(alias.id)
            #expect(navigation.recent == [NoteNavigation.identity(a.id)])
            #expect(navigation.ordered([a, alias]).count == 1)

            defaults.set([alias.id.absoluteString, a.id.absoluteString, "https://example.com", "invalid"], forKey: "pinnedNoteURLs")
            defaults.set([alias.id.absoluteString, a.id.absoluteString], forKey: "recentNoteURLs")
            let restored = NoteNavigation(defaults: defaults)
            #expect(restored.pinned == [NoteNavigation.identity(a.id)])
            #expect(restored.recent == [NoteNavigation.identity(a.id)])
        }
    }

    @Test func boundsHistoryIncludingPersistedHistoryAndReopens() throws {
        try withNavigation { navigation, defaults in
            let notes = (0..<(NoteNavigation.historyLimit + 20)).map { note("\($0).md") }
            for note in notes { navigation.recordOpened(note.id) }
            #expect(navigation.recent.count == NoteNavigation.historyLimit)
            #expect(!navigation.recent.contains(NoteNavigation.identity(notes[0].id)))
            navigation.recordOpened(notes[30].id)
            #expect(navigation.recent.first == NoteNavigation.identity(notes[30].id))
            #expect(Set(navigation.recent).count == NoteNavigation.historyLimit)
            #expect(NoteNavigation(defaults: defaults).recent == navigation.recent)

            defaults.set(notes.map { $0.id.absoluteString }, forKey: "recentNoteURLs")
            #expect(NoteNavigation(defaults: defaults).recent.count == NoteNavigation.historyLimit)
        }
    }

    @Test func ignoresMissingNotesAndBreaksModifiedDateTiesDeterministically() throws {
        try withNavigation { navigation, _ in
            let a = note("A.md")
            let b = note("B.md")
            let missing = note("Missing.md")
            navigation.togglePin(missing.id)
            navigation.recordOpened(missing.id)
            #expect(navigation.ordered([b, a]).map(\.id) == [a.id, b.id])
            #expect(navigation.ordered([a, b]).map(\.id) == [a.id, b.id])
        }
    }

    @Test func meaningfulMatchesOutrankWeakPinnedMatches() throws {
        try withNavigation { navigation, _ in
            let weak = note("North east.md")
            let exact = note("Note.md")
            let prefix = note("Notebook.md")
            navigation.togglePin(weak.id)
            let ordered = navigation.ordered([weak, exact, prefix])
            #expect(ordered.first?.id == weak.id)
            #expect(FuzzyMatcher.ranked(ordered, query: "note", fields: { [$0.title] }).map(\.id) == [exact.id, prefix.id, weak.id])
        }
    }

    private func note(_ path: String, modified: TimeInterval = 0) -> Note {
        Note(url: URL(fileURLWithPath: "/test-vault/" + path), modified: Date(timeIntervalSince1970: modified))
    }

    private func withNavigation(_ test: (NoteNavigation, UserDefaults) throws -> Void) throws {
        let suite = "PortalTests.NoteNavigation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try test(NoteNavigation(defaults: defaults), defaults)
    }
}
