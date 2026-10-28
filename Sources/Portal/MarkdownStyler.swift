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
    /// Block decoration drawn behind the text.
    static let markdownBlock = NSAttributedString.Key("PortalMarkdownBlock")
}

enum MarkdownBlock: String {
    case code, quote, rule
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
        func hide(_ ranges: NSRange...) {
            for range in ranges where range.location != NSNotFound {
                storage.addAttributes([.markdownMarker: true, .foregroundColor: NSColor.tertiaryLabelColor], range: range)
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
        for m in matches(link) {
            if let url = URL(string: string.substring(with: m.range(at: 4))) {
                storage.addAttributes([.link: url, .foregroundColor: NSColor.controlAccentColor], range: m.range(at: 2))
            }
            hide(m.range(at: 1), m.range(at: 3))
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
        storage.endEditing()
    }

    private static func addTrait(_ trait: NSFontTraitMask, to storage: NSTextStorage, in range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let font = value as? NSFont else { return }
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: subrange)
        }
    }
}
