import AppKit

extension NSAttributedString.Key {
    /// Markdown syntax that is hidden unless the caret is on its line.
    static let markdownMarker = NSAttributedString.Key("PortalMarkdownMarker")
    /// List marker (`-`, `*`, `+`) drawn as a bullet.
    static let markdownBullet = NSAttributedString.Key("PortalMarkdownBullet")
    /// `[ ]` / `[x]` drawn as a checkbox; the value is whether it is checked.
    static let markdownCheckbox = NSAttributedString.Key("PortalMarkdownCheckbox")
    /// Inline code drawn with a rounded background.
    static let markdownInlineCode = NSAttributedString.Key("PortalMarkdownInlineCode")
    /// Lines that take no space unless the caret is on them (empty front matter).
    static let markdownCollapsed = NSAttributedString.Key("PortalMarkdownCollapsed")
    /// Image shown in place of an embed line; the value is an `ImageEmbed`.
    static let markdownImage = NSAttributedString.Key("PortalMarkdownImage")
    /// Block decoration drawn behind the text.
    static let markdownBlock = NSAttributedString.Key("PortalMarkdownBlock")
    /// Hidden syntax that advances to the next tab stop instead (table pipes).
    static let markdownTab = NSAttributedString.Key("PortalMarkdownTab")
    /// A block shown as an image unless the caret is in it; the value is a `RenderedBlock`.
    static let markdownRendered = NSAttributedString.Key("PortalMarkdownRendered")
    /// A table row drawn in a grid; the value is a `TableRow`.
    static let markdownTableRow = NSAttributedString.Key("PortalMarkdownTableRow")
}

enum MarkdownBlock: String {
    case code, quote, rule
}

/// An image embed: `![[image.png|300]]` or `![alt](path/to/image.png)`.
final class ImageEmbed: NSObject {
    let source: String
    /// Obsidian `![[…]]` embeds are found anywhere in the vault; `![](…)` paths are relative.
    let isWikilink: Bool
    let width: CGFloat?

    init(source: String, isWikilink: Bool, width: CGFloat?) {
        self.source = source
        self.isWikilink = isWikilink
        self.width = width
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg"]
}

/// A block drawn from its source: a Mermaid diagram or LaTeX math.
final class RenderedBlock: NSObject, Sendable {
    enum Kind: String {
        case mermaid, math
    }

    let kind: Kind
    let source: String
    /// The block's characters, so its lines can make way for the image.
    let range: NSRange

    init(kind: Kind, source: String, range: NSRange) {
        self.kind = kind
        self.source = source
        self.range = range
    }
}

/// A table row's grid: column edges from the left of the text, and whether it is the header.
final class TableRow: NSObject {
    let edges: [CGFloat]
    let isHeader: Bool

    init(edges: [CGFloat], isHeader: Bool) {
        self.edges = edges
        self.isHeader = isHeader
    }
}

/// Styles Markdown source in place so the editor reads like rendered text.
@MainActor
enum MarkdownStyler {
    nonisolated static let baseFontSize: CGFloat = 16
    /// Task checkboxes are drawn a bit larger than the text, with extra room after `[ ]` to fit.
    nonisolated static let checkboxSize: CGFloat = 20
    private static let checkboxExtraWidth: CGFloat = 6
    static let baseFont = NSFont.systemFont(ofSize: baseFontSize)
    static let monoFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    static let tabWidth: CGFloat = 24

    static var baseAttributes: [NSAttributedString.Key: Any] {
        baseAttributes(for: EditorTypography())
    }

    static func baseAttributes(for typography: EditorTypography) -> [NSAttributedString.Key: Any] {
        [.font: typography.baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraphStyle(typography)]
    }

    private static func paragraphStyle(_ typography: EditorTypography, _ configure: (NSMutableParagraphStyle) -> Void = { _ in }) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = typography.scaled(3)
        style.tabStops = []
        style.defaultTabInterval = typography.scaled(tabWidth)
        configure(style)
        return style
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
    }

    private static let heading = regex(#"^(#{1,6}[ \t]+)(.+)$"#)
    private static let bold = regex(#"(\*\*|__)(?=[^\s*_])(.+?)(?<=[^\s*_])(\1)"#)
    private static let italic = regex(#"(?<![*_\w])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])(\1)(?![*_\w])"#)
    private static let strike = regex(#"(~~)(?=\S)(.+?)(?<=\S)(~~)"#)
    private static let codeSpan = regex(#"(`)([^`\n]+)(`)"#)
    static let wikilinkScheme = "portal-wikilink"
    private static let wikilink = regex(#"(!?\[\[)([^\]|\n]+)(\|[^\]\n]*)?(\]\])"#)
    private static let frontmatter = regex(#"\A---\n(?:[\s\S]*?\n)?---[ \t]*$"#)

    /// Where a note's content starts, after any front matter.
    static func bodyStart(of text: NSString) -> Int {
        guard let match = frontmatter.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) else { return 0 }
        let end = NSMaxRange(match.range)
        return end < text.length ? end + 1 : end
    }
    private static let imageEmbed = regex(#"^[ \t]*(?:!\[\[([^\]|\n]+)(?:\|([^\]\n]*))?\]\]|!\[([^\]\n]*)\]\(([^)\n]+)\))[ \t]*$"#)
    private static let link = regex(#"(\[)([^\]\n]+)(\]\(([^)\s]+)\))"#)
    private static let listItem = regex(#"^([ \t]*)([-*+]|\d+[.)])([ \t]+)(\[[ xX]\][ \t]+)?(.*)$"#)
    private static let quote = regex(#"^[ \t]*(>[ \t]?)(.*)$"#)
    private static let rule = regex(#"^[ \t]*(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$"#)
    private static let table = regex(#"^.*\|.*\n(?=.*\|)[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*(?:\n.*\|.*)*$"#)
    private static let tableCellPadding: CGFloat = 10
    private static let mathBlock = regex(#"^[ \t]*\$\$([\s\S]+?)\$\$[ \t]*$"#)
    private static let codeBlock = regex(#"^(```[^\n]*)\n([\s\S]*?)\n?^(```)[ \t]*$"#)

    static func style(_ storage: NSTextStorage, typography: EditorTypography = EditorTypography()) {
        let baseAttributes = baseAttributes(for: typography)
        let monoFont = typography.monoFont
        let checkboxExtraWidth = typography.scaled(Self.checkboxExtraWidth)
        let string = storage.string as NSString
        let full = NSRange(location: 0, length: storage.length)
        func matches(_ regex: NSRegularExpression) -> [NSTextCheckingResult] {
            regex.matches(in: storage.string, range: full)
        }
        func hide(_ ranges: NSRange..., color: NSColor = .tertiaryLabelColor) {
            for range in ranges where range.location != NSNotFound {
                storage.addAttributes([.markdownMarker: true, .foregroundColor: color], range: range)
            }
        }
        func width(_ text: String) -> CGFloat {
            NSAttributedString(string: text, attributes: baseAttributes).size().width
        }

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)

        for m in matches(heading) {
            let level = m.range(at: 1).length - 1
            let size = typography.headingSize(level: level)
            storage.addAttributes([
                .font: NSFont.systemFont(ofSize: size, weight: .bold),
                .paragraphStyle: paragraphStyle(typography) {
                    $0.paragraphSpacingBefore = typography.scaled(level <= 2 ? 12 : 8)
                    $0.paragraphSpacing = typography.scaled(4)
                },
            ], range: m.range)
            hide(m.range(at: 1))
        }
        for m in matches(bold) {
            addTrait(.boldFontMask, to: storage, in: m.range(at: 2))
            hide(m.range(at: 1), m.range(at: 3))
        }
        for m in matches(italic) {
            addTrait(.italicFontMask, to: storage, in: m.range(at: 2))
            hide(m.range(at: 1), m.range(at: 3))
        }
        for m in matches(strike) {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 2))
            hide(m.range(at: 1), m.range(at: 3))
        }
        for m in matches(codeSpan) {
            storage.addAttributes([.font: monoFont, .markdownInlineCode: true], range: m.range(at: 2))
            hide(m.range(at: 1), m.range(at: 3))
        }
        for m in matches(wikilink) {
            let target = string.substring(with: m.range(at: 2))
            var url = URLComponents()
            url.scheme = wikilinkScheme
            url.path = "open"
            url.queryItems = [URLQueryItem(name: "target", value: target)]
            guard let link = url.url else { continue }
            let alias = m.range(at: 3)
            // `[[target|alias]]` shows only the alias.
            let shown = alias.location == NSNotFound ? m.range(at: 2) : NSRange(location: alias.location + 1, length: alias.length - 1)
            storage.addAttributes([
                .link: link,
                .foregroundColor: NSColor.controlAccentColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: shown)
            hide(NSRange(location: m.range.location, length: shown.location - m.range.location), m.range(at: 4), color: .secondaryLabelColor)
        }
        for m in matches(link) {
            if let url = URL(string: string.substring(with: m.range(at: 4))) {
                storage.addAttributes([
                    .link: url,
                    .foregroundColor: NSColor.controlAccentColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: m.range(at: 2))
            }
            hide(m.range(at: 1), m.range(at: 3), color: .secondaryLabelColor)
        }
        for m in matches(imageEmbed) {
            let isWikilink = m.range(at: 1).location != NSNotFound
            let source = string.substring(with: m.range(at: isWikilink ? 1 : 4)).trimmingCharacters(in: .whitespaces)
            guard ImageEmbed.imageExtensions.contains((source as NSString).pathExtension.lowercased()) else { continue }
            // Obsidian sizes images with `![[image.png|300]]` or `![alt|300](image.png)`.
            let sizeGroup = m.range(at: isWikilink ? 2 : 3)
            let size = sizeGroup.location == NSNotFound ? nil : string.substring(with: sizeGroup).split(separator: "|").last
            let width = size.flatMap { Double($0.split(separator: "x").first ?? "") }.map { CGFloat($0) }
            storage.removeAttribute(.link, range: m.range)
            // Shown while editing the line: the file name reads like a link, the syntax around it a step quieter.
            hide(m.range, color: .secondaryLabelColor)
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: m.range(at: isWikilink ? 1 : 4))
            storage.addAttribute(.markdownImage, value: ImageEmbed(source: source, isWikilink: isWikilink, width: width), range: m.range)
        }
        for m in matches(table) {
            styleTable(m.range, in: storage, typography: typography) { hide($0) }
        }
        for m in matches(listItem) {
            let indent = string.substring(with: m.range(at: 1))
            let marker = m.range(at: 2)
            let box = m.range(at: 4)
            let isBullet = "-*+".contains(string.substring(with: marker))
            var visiblePrefix = indent + string.substring(with: NSRange(location: marker.location, length: NSMaxRange(m.range(at: 3)) - marker.location))

            if isBullet, box.location != NSNotFound {
                // Task: the dash is syntax, the box is drawn as a checkbox.
                let checkbox = NSRange(location: box.location, length: 3)
                let done = string.substring(with: checkbox) != "[ ]"
                hide(NSRange(location: marker.location, length: box.location - marker.location))
                storage.addAttributes([
                    .markdownCheckbox: done,
                    .foregroundColor: NSColor.clear,
                    .link: URL(string: "task:\(checkbox.location)")!,
                ], range: checkbox)
                // Pad every box to the width of `[x]` plus the extra room, so task text lines up checked or not.
                let padding = checkboxExtraWidth + width("[x]") - width(string.substring(with: checkbox))
                storage.addAttribute(.kern, value: padding, range: NSRange(location: checkbox.location + 2, length: 1))
                if done {
                    storage.addAttributes([
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ], range: m.range(at: 5))
                }
                visiblePrefix = indent + "[x] "
            } else {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: marker)
                if isBullet { storage.addAttribute(.markdownBullet, value: true, range: marker) }
            }
            let hangingIndent = width(visiblePrefix) + (box.location != NSNotFound && isBullet ? checkboxExtraWidth : 0)
            storage.addAttribute(.paragraphStyle, value: paragraphStyle(typography) { $0.headIndent = hangingIndent }, range: m.range)
        }
        for m in matches(quote) {
            hide(m.range(at: 1))
            storage.addAttributes([
                .foregroundColor: NSColor.secondaryLabelColor,
                .markdownBlock: MarkdownBlock.quote.rawValue,
                .paragraphStyle: paragraphStyle(typography) {
                    $0.firstLineHeadIndent = typography.scaled(14)
                    $0.headIndent = typography.scaled(14)
                },
            ], range: string.lineRange(for: m.range)) // Include the newline so consecutive lines share one bar.
        }
        for m in matches(rule) {
            hide(m.range)
            storage.addAttribute(.markdownBlock, value: MarkdownBlock.rule.rawValue, range: m.range)
        }
        var codeAttributes = baseAttributes
        codeAttributes[.font] = monoFont
        codeAttributes[.markdownBlock] = MarkdownBlock.code.rawValue
        codeAttributes[.paragraphStyle] = paragraphStyle(typography) {
            $0.firstLineHeadIndent = typography.scaled(12)
            $0.headIndent = typography.scaled(12)
            $0.tailIndent = typography.scaled(-12)
        }
        for m in matches(mathBlock) {
            var attributes = codeAttributes
            attributes[.markdownMarker] = true
            attributes[.markdownRendered] = RenderedBlock(kind: .math, source: string.substring(with: m.range(at: 1)), range: m.range)
            storage.setAttributes(attributes, range: m.range)
        }
        for m in matches(codeBlock) {
            storage.setAttributes(codeAttributes, range: m.range)
            let code = m.range(at: 2)
            let language = string.substring(with: m.range(at: 1)).dropFirst(3).split(separator: " ").first.map(String.init) ?? ""
            for token in SyntaxHighlighter.tokens(in: string.substring(with: code), language: language.lowercased()) {
                storage.addAttribute(.foregroundColor, value: token.color, range: NSRange(location: code.location + token.range.location, length: token.range.length))
            }
            if let kind = RenderedBlock.Kind(rawValue: language.lowercased()) {
                hide(m.range, color: .labelColor)
                storage.addAttribute(.markdownRendered, value: RenderedBlock(kind: kind, source: string.substring(with: code), range: m.range), range: m.range)
            }
            for fence in [m.range(at: 1), m.range(at: 3)] {
                storage.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: typography.scaled(11), weight: .medium),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ], range: fence)
            }
        }
        for m in matches(frontmatter) {
            var attributes = baseAttributes
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: typography.scaled(12), weight: .regular)
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
            // Like Obsidian, empty properties are not shown.
            let properties = string.substring(with: m.range).split(separator: "\n").dropFirst().dropLast()
            if properties.allSatisfy({ $0.allSatisfy(\.isWhitespace) }) {
                attributes[.markdownMarker] = true
                attributes[.markdownCollapsed] = true
            }
            storage.setAttributes(attributes, range: m.range)
        }
        storage.endEditing()
    }

    /// Lines a table up in columns: off the active line its pipes act as tabs to stops past each column's widest cell.
    private static func styleTable(_ range: NSRange, in storage: NSTextStorage, typography: EditorTypography, hide: (NSRange) -> Void) {
        let string = storage.string as NSString
        var lines: [NSRange] = []
        string.enumerateSubstrings(in: range, options: [.byLines, .substringNotRequired]) { _, line, _, _ in lines.append(line) }

        /// Splits a row at its unescaped pipes outside code spans into cell ranges, plus its leading and trailing pipe.
        func split(_ line: NSRange) -> (cells: [NSRange], leading: NSRange?, trailing: NSRange?) {
            var pipes: [Int] = []
            var inCode = false
            var index = line.location
            while index < NSMaxRange(line) {
                switch string.character(at: index) {
                case 92: index += 1 // `\|`
                case 96: inCode.toggle()
                case 124 where !inCode: pipes.append(index)
                default: break
                }
                index += 1
            }
            let blank = { (r: NSRange) in string.substring(with: r).allSatisfy(\.isWhitespace) }
            let leading = pipes.first.flatMap { blank(NSRange(location: line.location, length: $0 - line.location)) ? $0 : nil }
            let trailing = pipes.last.flatMap { $0 != leading && blank(NSRange(location: $0 + 1, length: NSMaxRange(line) - $0 - 1)) ? $0 : nil }
            var start = leading.map { $0 + 1 } ?? line.location
            var cells: [NSRange] = []
            for pipe in pipes.filter({ $0 != leading && $0 != trailing }) + [trailing ?? NSMaxRange(line)] {
                cells.append(NSRange(location: start, length: pipe - start))
                start = pipe + 1
            }
            return (cells, leading.map { NSRange(location: line.location, length: $0 + 1 - line.location) },
                    trailing.map { NSRange(location: $0, length: NSMaxRange(line) - $0) })
        }
        func trimmed(_ cell: NSRange) -> NSRange {
            let text = string.substring(with: cell)
            let leading = text.prefix { $0.isWhitespace }.utf16.count
            let trailing = text.reversed().prefix { $0.isWhitespace }.count
            return NSRange(location: cell.location + leading, length: max(0, cell.length - leading - trailing))
        }
        /// The cell's width as shown off the active line, without its hidden syntax.
        func width(_ cell: NSRange) -> CGFloat {
            let shown = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: cell))
            shown.enumerateAttribute(.markdownMarker, in: NSRange(location: 0, length: shown.length), options: .reverse) { value, range, _ in
                if value != nil { shown.deleteCharacters(in: range) }
            }
            return ceil(shown.size().width)
        }

        let alignments: [NSTextAlignment] = split(lines[1]).cells.map {
            let spec = string.substring(with: trimmed($0))
            return spec.hasSuffix(":") ? (spec.hasPrefix(":") ? .center : .right) : .left
        }
        hide(lines[1])
        storage.addAttribute(.markdownCollapsed, value: true, range: lines[1])

        let rows = lines.enumerated().filter { $0.offset != 1 }.map { (line: $0.element, isHeader: $0.offset == 0, split: split($0.element)) }
        for row in rows where row.isHeader {
            for cell in row.split.cells { addTrait(.boldFontMask, to: storage, in: trimmed(cell)) }
        }
        var widths: [CGFloat] = []
        for row in rows {
            for (column, cell) in row.split.cells.enumerated() {
                let cellWidth = width(trimmed(cell))
                if column < widths.count { widths[column] = max(widths[column], cellWidth) } else { widths.append(cellWidth) }
            }
        }
        let padding = typography.scaled(tableCellPadding)
        let edges = widths.reduce(into: [CGFloat(0)]) { $0.append($0.last! + $1 + padding * 2) }
        let tabs = widths.indices.map { column in
            let alignment = column < alignments.count ? alignments[column] : .left
            let offset = alignment == .center ? widths[column] / 2 : alignment == .right ? widths[column] : 0
            return NSTextTab(textAlignment: alignment, location: edges[column] + padding + offset)
        }

        for row in rows {
            let (cells, leading, trailing) = row.split
            for (column, cell) in cells.enumerated() {
                let content = trimmed(cell)
                hide(NSRange(location: cell.location, length: content.location - cell.location))
                hide(NSRange(location: NSMaxRange(content), length: NSMaxRange(cell) - NSMaxRange(content)))
                // The pipe before each cell after the first moves on to that cell's column.
                if column > 0 { storage.addAttribute(.markdownTab, value: true, range: NSRange(location: cell.location - 1, length: 1)) }
            }
            if let leading {
                hide(leading)
                storage.addAttribute(.markdownTab, value: true, range: NSRange(location: NSMaxRange(leading) - 1, length: 1))
            }
            if let trailing { hide(trailing) }
            for column in cells.indices.dropFirst() { hide(NSRange(location: cells[column].location - 1, length: 1)) }
            storage.addAttributes([
                .markdownTableRow: TableRow(edges: edges, isHeader: row.isHeader),
                .paragraphStyle: paragraphStyle(typography) {
                    $0.lineSpacing = 0
                    $0.paragraphSpacingBefore = typography.scaled(5)
                    $0.paragraphSpacing = typography.scaled(5)
                    $0.tabStops = tabs
                    $0.firstLineHeadIndent = leading == nil ? padding : 0
                },
            ], range: row.line)
        }
    }

    private static func addTrait(_ trait: NSFontTraitMask, to storage: NSTextStorage, in range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let font = value as? NSFont else { return }
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: subrange)
        }
    }
}
