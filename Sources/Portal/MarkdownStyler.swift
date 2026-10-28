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

/// Styles Markdown source in place so the editor reads like rendered text.
@MainActor
enum MarkdownStyler {
    static let baseFont = NSFont.systemFont(ofSize: 14)
    static let monoFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let tabWidth: CGFloat = 24

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraphStyle()]
    }

    private static func paragraphStyle(_ configure: (NSMutableParagraphStyle) -> Void = { _ in }) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.tabStops = []
        style.defaultTabInterval = tabWidth
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
    private static let codeBlock = regex(#"^(```[^\n]*)\n([\s\S]*?)\n?^(```)[ \t]*$"#)

    static func style(_ storage: NSTextStorage) {
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
            let size: CGFloat = [26, 21, 18, 16, 15, 14][min(level, 6) - 1]
            storage.addAttributes([
                .font: NSFont.systemFont(ofSize: size, weight: .bold),
                .paragraphStyle: paragraphStyle {
                    $0.paragraphSpacingBefore = level <= 2 ? 12 : 8
                    $0.paragraphSpacing = 4
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
            storage.addAttributes([.link: link, .foregroundColor: NSColor.controlAccentColor], range: shown)
            hide(NSRange(location: m.range.location, length: shown.location - m.range.location), m.range(at: 4), color: .secondaryLabelColor)
        }
        for m in matches(link) {
            if let url = URL(string: string.substring(with: m.range(at: 4))) {
                storage.addAttributes([.link: url, .foregroundColor: NSColor.controlAccentColor], range: m.range(at: 2))
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
                if done {
                    storage.addAttributes([
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ], range: m.range(at: 5))
                }
                visiblePrefix = indent + string.substring(with: box)
            } else {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: marker)
                if isBullet { storage.addAttribute(.markdownBullet, value: true, range: marker) }
            }
            let hangingIndent = width(visiblePrefix)
            storage.addAttribute(.paragraphStyle, value: paragraphStyle { $0.headIndent = hangingIndent }, range: m.range)
        }
        for m in matches(quote) {
            hide(m.range(at: 1))
            storage.addAttributes([
                .foregroundColor: NSColor.secondaryLabelColor,
                .markdownBlock: MarkdownBlock.quote.rawValue,
                .paragraphStyle: paragraphStyle {
                    $0.firstLineHeadIndent = 14
                    $0.headIndent = 14
                },
            ], range: string.lineRange(for: m.range)) // Include the newline so consecutive lines share one bar.
        }
        for m in matches(rule) {
            hide(m.range)
            storage.addAttribute(.markdownBlock, value: MarkdownBlock.rule.rawValue, range: m.range)
        }
        for m in matches(codeBlock) {
            var attributes = baseAttributes
            attributes[.font] = monoFont
            attributes[.markdownBlock] = MarkdownBlock.code.rawValue
            attributes[.paragraphStyle] = paragraphStyle {
                $0.firstLineHeadIndent = 12
                $0.headIndent = 12
                $0.tailIndent = -12
            }
            storage.setAttributes(attributes, range: m.range)
            for fence in [m.range(at: 1), m.range(at: 3)] {
                storage.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ], range: fence)
            }
        }
        for m in matches(frontmatter) {
            var attributes = baseAttributes
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
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

    private static func addTrait(_ trait: NSFontTraitMask, to storage: NSTextStorage, in range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let font = value as? NSFont else { return }
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: subrange)
        }
    }
}
