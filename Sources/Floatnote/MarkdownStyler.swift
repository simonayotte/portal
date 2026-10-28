import AppKit

extension NSAttributedString.Key {
    /// Markdown syntax that is hidden unless the caret is on its line.
    static let markdownMarker = NSAttributedString.Key("FloatnoteMarkdownMarker")
}

/// Styles Markdown source in place so the editor reads like rendered text.
@MainActor
enum MarkdownStyler {
    static let baseFont = NSFont.systemFont(ofSize: 14)
    static let monoFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        return [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
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
    private static let listMarker = regex(#"^[ \t]*(?:[-*+]|\d+[.)])(?=[ \t])"#)
    private static let task = regex(#"^[ \t]*[-*+][ \t]+(\[[ xX]\])[ \t]+(.*)$"#)
    private static let quote = regex(#"^[ \t]*(>[ \t]?)(.*)$"#)
    private static let rule = regex(#"^[ \t]*(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$"#)
    private static let codeBlock = regex(#"^```[^\n]*\n[\s\S]*?^```[^\n]*$"#)

    static func style(_ storage: NSTextStorage) {
        let string = storage.string
        let full = NSRange(location: 0, length: storage.length)
        func matches(_ regex: NSRegularExpression) -> [NSTextCheckingResult] {
            regex.matches(in: string, range: full)
        }
        func hide(_ ranges: NSRange...) {
            for range in ranges {
                storage.addAttributes([.markdownMarker: true, .foregroundColor: NSColor.tertiaryLabelColor], range: range)
            }
        }

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)

        for m in matches(heading) {
            let level = m.range(at: 1).length - 1
            let size: CGFloat = [26, 21, 18, 16, 15, 14][min(level, 6) - 1]
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacingBefore = 6
            storage.addAttributes([.font: NSFont.systemFont(ofSize: size, weight: .bold), .paragraphStyle: paragraph], range: m.range)
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
            storage.addAttributes([.font: monoFont, .backgroundColor: NSColor.quaternarySystemFill], range: m.range(at: 2))
            hide(m.range(at: 1), m.range(at: 3))
        }
        for m in matches(link) {
            let url = (string as NSString).substring(with: m.range(at: 4))
            if let url = URL(string: url) { storage.addAttribute(.link, value: url, range: m.range(at: 2)) }
            hide(m.range(at: 1), m.range(at: 3))
        }
        for m in matches(listMarker) {
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: m.range)
        }
        for m in matches(task) {
            let box = m.range(at: 1)
            storage.addAttribute(.link, value: URL(string: "task:\(box.location)")!, range: box)
            if (string as NSString).substring(with: box) != "[ ]" {
                storage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ], range: m.range(at: 2))
            }
        }
        for m in matches(quote) {
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: m.range(at: 1))
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range(at: 2))
            addTrait(.italicFontMask, to: storage, in: m.range(at: 2))
        }
        for m in matches(rule) {
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: m.range)
        }
        for m in matches(codeBlock) {
            var attributes = baseAttributes
            attributes[.font] = monoFont
            attributes[.backgroundColor] = NSColor.quaternarySystemFill
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
