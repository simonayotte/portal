import Foundation

/// Title/path matching only; higher-quality matches always outrank list order.
enum FuzzyMatcher {
    struct Score: Comparable {
        let kind: Int
        let quality: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.kind, lhs.quality) < (rhs.kind, rhs.quality)
        }
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func ranked<Item>(_ items: [Item], query: String, fields: (Item) -> [String]) -> [Item] {
        let query = Array(normalized(query.trimmingCharacters(in: .whitespacesAndNewlines)))
        guard !query.isEmpty else { return items }
        return items.enumerated().compactMap { index, item -> (index: Int, item: Item, score: Score)? in
            guard let score = fields(item).compactMap({ Self.score(query, in: $0) }).max() else { return nil }
            return (index, item, score)
        }.sorted {
            $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score
        }.map(\.item)
    }

    static func score(_ query: String, in text: String) -> Score? {
        score(Array(normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))), in: text)
    }

    private static func score(_ query: [Character], in text: String) -> Score? {
        let text = Array(normalized(text))
        guard !query.isEmpty else { return Score(kind: 0, quality: 0) }
        guard query.count <= text.count else { return nil }
        if query == text { return Score(kind: 5, quality: 0) }

        func boundary(_ index: Int) -> Bool {
            index == 0 || (!text[index - 1].isLetter && !text[index - 1].isNumber)
        }

        var contiguous: Score?
        for start in 0...(text.count - query.count) where text[start..<(start + query.count)].elementsEqual(query) {
            let candidate = Score(kind: start == 0 ? 4 : (boundary(start) ? 3 : 2), quality: -start - text.count)
            if let best = contiguous, best >= candidate { continue }
            contiguous = candidate
        }
        if let contiguous { return contiguous }

        // Best subsequence, not just the first greedy match: reward boundaries and
        // adjacent characters, penalize gaps. Two rolling rows keep space linear.
        var previous = [Int?](repeating: nil, count: text.count)
        for (offset, character) in query.enumerated() {
            var current = [Int?](repeating: nil, count: text.count)
            var bestEarlier: Int?
            for index in text.indices {
                if index > 0, let value = previous[index - 1] {
                    bestEarlier = max(bestEarlier ?? Int.min, value + index - 1)
                }
                guard character == text[index] else { continue }
                let bonus = boundary(index) ? 12 : 0
                if offset == 0 {
                    current[index] = bonus - index
                } else if let bestEarlier {
                    var value = bestEarlier - index + bonus
                    if index > 0, let adjacent = previous[index - 1] {
                        value = max(value, adjacent + bonus + 8)
                    }
                    current[index] = value
                }
            }
            previous = current
        }
        return previous.compactMap(\.self).max().map { Score(kind: 1, quality: $0 - text.count) }
    }
}
