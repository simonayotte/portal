import AppKit
import JavaScriptCore

/// Colors code block tokens with highlight.js and GitHub's light and dark themes.
@MainActor
enum SyntaxHighlighter {
    typealias Token = (range: NSRange, color: NSColor)

    private static let highlight: JSValue? = {
        guard let url = Bundle.main.url(forResource: "highlight.min", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { return nil }
        context.evaluateScript(script)
        return context.evaluateScript("""
            (code, language) => hljs.getLanguage(language) ? hljs.highlight(code, { language }).value : null
            """)
    }()
    /// Tokens of recently highlighted blocks, since the whole note is restyled on every edit.
    private static var cache: [String: [Token]] = [:]

    /// Token colors for `code`, relative to its start; none for an unknown language.
    static func tokens(in code: String, language: String) -> [Token] {
        let key = language + "\n" + code
        if let tokens = cache[key] { return tokens }
        guard let html = highlight?.call(withArguments: [code, language]), html.isString else { return [] }
        let tokens = parse(html.toString())
        if cache.count > 100 { cache.removeAll() }
        cache[key] = tokens
        return tokens
    }

    /// Reads token ranges from highlight.js's `<span class="hljs-…">` markup, outer spans first so inner ones win.
    private static func parse(_ html: String) -> [Token] {
        var spans: [(start: Int, end: Int, color: NSColor?)] = []
        var open: [Int] = []
        var offset = 0
        var index = html.startIndex
        while index < html.endIndex {
            switch html[index] {
            case "<":
                guard let close = html[index...].firstIndex(of: ">") else { return [] }
                let tag = html[index...close]
                if tag.hasPrefix("</") {
                    if let span = open.popLast() { spans[span].end = offset }
                } else {
                    let classes = tag.split(separator: "\"").dropFirst().first?.split(separator: " ").map(String.init) ?? []
                    open.append(spans.count)
                    spans.append((offset, offset, color(for: classes)))
                }
                index = html.index(after: close)
            case "&":
                // Every entity highlight.js writes (`&lt;`, `&#x27;` …) stands for a single UTF-16 unit.
                guard let semicolon = html[index...].firstIndex(of: ";") else { return [] }
                offset += 1
                index = html.index(after: semicolon)
            default:
                offset += html[index].utf16.count
                index = html.index(after: index)
            }
        }
        return spans.compactMap { span in
            span.color.map { (NSRange(location: span.start, length: span.end - span.start), $0) }
        }
    }

    private static func color(for classes: [String]) -> NSColor? {
        guard let scope = classes.first?.replacingOccurrences(of: "hljs-", with: "") else { return nil }
        return scope == "variable" && classes.contains("language_") ? theme["keyword"] : theme[scope]
    }

    /// GitHub's highlight.js themes (github.css and github-dark.css).
    private static let theme: [String: NSColor] = {
        let groups: [(scopes: [String], light: Int, dark: Int)] = [
            (["doctag", "keyword", "template-tag", "template-variable", "type"], 0xd73a49, 0xff7b72),
            (["title"], 0x6f42c1, 0xd2a8ff),
            (["attr", "attribute", "literal", "meta", "number", "operator", "variable",
              "selector-attr", "selector-class", "selector-id", "section"], 0x005cc5, 0x79c0ff),
            (["regexp", "string"], 0x032f62, 0xa5d6ff),
            (["built_in", "symbol"], 0xe36209, 0xffa657),
            (["comment", "code", "formula"], 0x6a737d, 0x8b949e),
            (["name", "quote", "selector-tag", "selector-pseudo", "addition"], 0x22863a, 0x7ee787),
            (["bullet"], 0x735c0f, 0xf2cc60),
            (["deletion"], 0xb31d28, 0xffdcd7),
        ]
        var theme: [String: NSColor] = [:]
        for group in groups {
            let color = NSColor(name: nil) { appearance in
                let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? group.dark : group.light
                return NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
            }
            for scope in group.scopes { theme[scope] = color }
        }
        return theme
    }()
}
