import AppKit

/// Renders the decorations the styler marks up: hides syntax off the active line,
/// swaps list dashes for bullets, and draws checkboxes, quote bars, rules and code backgrounds.
final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    /// Character range of the line(s) holding the selection; syntax stays visible there.
    var activeLine = NSRange()

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func isActive(_ index: Int) -> Bool { NSLocationInRange(index, activeLine) }

    // MARK: Glyphs

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard let storage = textStorage else { return 0 }
        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        var newProperties = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
        var changed = false
        for i in newGlyphs.indices {
            let index = characterIndexes[i]
            let attributes = storage.attributes(at: index, effectiveRange: nil)
            if attributes[.markdownMarker] != nil, !isActive(index) {
                // A zero-width control glyph stays on its own line (`.null` glyphs drift to the previous one).
                newProperties[i] = .controlCharacter
                changed = true
            } else if attributes[.markdownBullet] != nil {
                var bullet: UniChar = 0x2022
                CTFontGetGlyphsForCharacters(font, &bullet, &newGlyphs[i], 1)
                changed = true
            }
        }
        guard changed else { return 0 }
        newGlyphs.withUnsafeBufferPointer { glyphs in
            newProperties.withUnsafeBufferPointer { properties in
                setGlyphs(glyphs.baseAddress!, properties: properties.baseAddress!, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
            }
        }
        return glyphRange.length
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        let isMarker = textStorage?.attribute(.markdownMarker, at: charIndex, effectiveRange: nil) != nil
        return isMarker && !isActive(charIndex) ? .zeroAdvancement : action
    }

    // MARK: Drawing

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let left = origin.x + container.lineFragmentPadding
        let width = container.size.width - container.lineFragmentPadding * 2

        storage.enumerateAttribute(.markdownBlock, in: characters) { value, range, _ in
            guard let block = (value as? String).flatMap(MarkdownBlock.init) else { return }
            let rect = lineFragmentsRect(for: range).offsetBy(dx: 0, dy: origin.y)
            switch block {
            case .code:
                NSColor.quaternarySystemFill.setFill()
                NSBezierPath(roundedRect: NSRect(x: left, y: rect.minY, width: width, height: rect.height), xRadius: 8, yRadius: 8).fill()
            case .quote:
                NSColor.controlAccentColor.withAlphaComponent(0.7).setFill()
                NSBezierPath(roundedRect: NSRect(x: left, y: rect.minY + 2, width: 3, height: rect.height - 4), xRadius: 1.5, yRadius: 1.5).fill()
            case .rule where !isActive(range.location):
                NSColor.separatorColor.setFill()
                NSRect(x: left, y: rect.midY.rounded(), width: width, height: 1).fill()
            case .rule:
                break
            }
        }

        storage.enumerateAttribute(.markdownInlineCode, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let noSelection = NSRange(location: NSNotFound, length: 0)
            NSColor.quaternarySystemFill.setFill()
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: noSelection, in: container) { rect, _ in
                let pill = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -3, dy: 0)
                NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
            }
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        storage.enumerateAttribute(.markdownCheckbox, in: characters) { value, range, _ in
            guard let done = value as? Bool else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let bounds = boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
            let colors: [NSColor] = done ? [.white, .controlAccentColor] : [.tertiaryLabelColor]
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: colors))
            guard let image = NSImage(systemSymbolName: done ? "checkmark.square.fill" : "square", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return }
            let rect = NSRect(
                x: bounds.midX - image.size.width / 2,
                y: bounds.midY - image.size.height / 2,
                width: image.size.width,
                height: image.size.height
            )
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private func lineFragmentsRect(for characters: NSRange) -> NSRect {
        var rect = NSRect.null
        enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: characters, actualCharacterRange: nil)) { fragment, _, _, _, _ in
            rect = rect.union(fragment)
        }
        return rect
    }
}
