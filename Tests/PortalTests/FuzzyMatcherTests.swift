import Foundation
import Testing
@testable import Portal

struct FuzzyMatcherTests {
    @Test func ranksExactPrefixWordBoundarySubstringAndSubsequence() {
        let titles = ["North east", "Footnote", "Daily Note", "Notebook", "Note", "Unrelated"]
        #expect(FuzzyMatcher.ranked(titles, query: "note", fields: { [$0] }) == [
            "Note", "Notebook", "Daily Note", "Footnote", "North east",
        ])
    }

    @Test func rewardsSubsequenceWordBoundariesAndCompactMatches() throws {
        let boundary = try #require(FuzzyMatcher.score("np", in: "Note Portal"))
        let scattered = try #require(FuzzyMatcher.score("np", in: "nondescript"))
        #expect(boundary > scattered)
        #expect(try #require(FuzzyMatcher.score("np", in: "Note Portal")) >
                #require(FuzzyMatcher.score("np", in: "New oversized project")))
    }

    @Test func foldsCaseDiacriticsAndCanonicalUnicode() {
        #expect(FuzzyMatcher.score("CAFE", in: "Café")?.kind == 5)
        #expect(FuzzyMatcher.score("resume", in: "Résumé")?.kind == 5)
        #expect(FuzzyMatcher.score("e\u{301}", in: "É")?.kind == 5)
        #expect(FuzzyMatcher.score("東京", in: "東京の旅")?.kind == 4)
        #expect(FuzzyMatcher.score("🐈‍⬛", in: "My 🐈‍⬛") != nil)
    }

    @Test func rejectsMissingRepeatedAndOutOfOrderCharacters() {
        for query in ["xyz", "nn", "et on", "notebook"] {
            #expect(FuzzyMatcher.score(query, in: "Note") == nil)
        }
    }

    @Test func matchesFoldersAndPathsWithoutSearchingContents() {
        let paths = ["Work/Planning/Café", "Personal/Recipes", "Work/Meeting"]
        #expect(FuzzyMatcher.ranked(paths, query: "wk/cf", fields: { [$0] }) == ["Work/Planning/Café"])
        #expect(FuzzyMatcher.ranked(paths, query: "planning", fields: { $0.split(separator: "/").map(String.init) }) == [
            "Work/Planning/Café",
        ])
    }

    @Test func keepsGenericActionOrderOnEmptyQueryAndStableTies() {
        let actions = [
            PaletteItem(id: "second", title: "Toggle Style") {},
            PaletteItem(id: "first", title: "Toggle Style") {},
            PaletteItem(id: "other", title: "Open Vault") {},
        ]
        for query in ["", " \n\t"] {
            #expect(FuzzyMatcher.ranked(actions, query: query, fields: { [$0.title] }).map(\.id) == actions.map(\.id))
        }
        #expect(FuzzyMatcher.ranked(actions, query: "toggle", fields: { [$0.title] }).map(\.id) == ["second", "first"])
    }
}
