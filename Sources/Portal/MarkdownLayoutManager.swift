import AppKit

/// Renders the decorations the styler marks up: hides syntax off the active line, swaps list dashes
/// for bullets, and draws checkboxes, quote bars, rules, code backgrounds and embedded images.
final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    /// Character range of the line(s) holding the selection; syntax stays visible there.
    var activeLine = NSRange()
    /// Character Vim's block cursor sits on, or `nil` in Insert mode.
    var blockCursor: Int?
    /// Finds the file an image embed points to.
    var resolveImage: ((ImageEmbed) -> URL?)? {
        didSet {
            forgetImages()
            // Whether an embed's text hides depends on finding its image, so redo glyphs as well as layout.
            let all = NSRange(location: 0, length: textStorage?.length ?? 0)
            invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
            invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
        }
    }
    private var images: [URL: NSImage] = [:]
    /// Resolved embed sources (including misses), until the next note loads.
    private var resolved: [String: URL?] = [:]
    private static let imageSpacing: CGFloat = 10
    private static let maxImageHeight: CGFloat = 480

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func isActive(_ index: Int) -> Bool { NSLocationInRange(index, activeLine) }

    /// Syntax off the active line is hidden; an image embed's text only when its image can be shown.
    private func isHiddenMarker(at index: Int) -> Bool {
        guard !isActive(index), let storage = textStorage,
              storage.attribute(.markdownMarker, at: index, effectiveRange: nil) != nil else { return false }
        if let embed = storage.attribute(.markdownImage, at: index, effectiveRange: nil) as? ImageEmbed {
            return image(for: embed) != nil
        }
        return true
    }

    // MARK: Images

    /// Drops resolved image paths, e.g. when another note (with other relative paths) loads.
    func forgetImages() {
        images.removeAll()
        resolved.removeAll()
    }

    private func image(for embed: ImageEmbed) -> NSImage? {
        let key = "\(embed.isWikilink)|\(embed.source)"
        let url = resolved[key] ?? resolveImage?(embed)
        resolved[key] = url
        guard let url else { return nil }
        if let image = images[url] { return image }
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else { return nil }
        images[url] = image
        return image
    }

    /// Fits the image to the text width (or the embed's `|width`) without upscaling, capped in height.
    private func size(of image: NSImage, for embed: ImageEmbed, in container: NSTextContainer) -> NSSize {
        let available = container.size.width - container.lineFragmentPadding * 2
        var width = min(embed.width ?? image.size.width, image.size.width, available)
        var height = image.size.height * width / image.size.width
        if height > Self.maxImageHeight {
            width *= Self.maxImageHeight / height
            height = Self.maxImageHeight
        }
        return NSSize(width: width, height: height)
    }

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
            if attributes[.markdownMarker] != nil, isHiddenMarker(at: index) {
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
        guard isHiddenMarker(at: charIndex) else { return action }
        return textStorage?.attribute(.markdownTab, at: charIndex, effectiveRange: nil) != nil ? .horizontalTab : .zeroAdvancement
    }

    /// Makes room for embedded images below their line, and collapses empty front matter
    /// unless the caret is on it.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        let index = characterIndexForGlyph(at: glyphRange.location)
        guard let storage = textStorage, index < storage.length else { return false }

        if let embed = storage.attribute(.markdownImage, at: index, effectiveRange: nil) as? ImageEmbed,
           let image = image(for: embed) {
            // Off the active line the image replaces its text; on it, the image sits below the text.
            let height = size(of: image, for: embed, in: textContainer).height + Self.imageSpacing
            let lineHeight = isActive(index) ? lineFragmentRect.pointee.height : 0
            lineFragmentRect.pointee.size.height = lineHeight + height
            lineFragmentUsedRect.pointee.size.height = lineHeight + height
            return true
        }

        guard !isActive(index), storage.attribute(.markdownCollapsed, at: index, effectiveRange: nil) != nil else { return false }
        lineFragmentRect.pointee.size.height = 0
        lineFragmentUsedRect.pointee.size.height = 0
        baselineOffset.pointee = 0
        return true
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

        storage.enumerateAttribute(.markdownTableRow, in: characters) { value, range, _ in
            // On the active line the row shows its Markdown source instead.
            guard let row = value as? TableRow, !isActive(range.location) else { return }
            let rect = lineFragmentsRect(for: range).offsetBy(dx: 0, dy: origin.y)
            let table = NSRect(x: left, y: rect.minY, width: row.edges.last ?? 0, height: rect.height)
            if row.isHeader {
                NSColor.quaternarySystemFill.setFill()
                table.fill()
            }
            NSColor.separatorColor.setFill()
            // Each row draws its bottom edge, and its top one unless the row above already did.
            if row.isHeader || isActive(range.location - 1) { NSRect(x: table.minX, y: table.minY, width: table.width, height: 1).fill() }
            NSRect(x: table.minX, y: table.maxY - 1, width: table.width, height: 1).fill()
            for edge in row.edges {
                NSRect(x: left + min(edge, table.width - 1), y: table.minY, width: 1, height: table.height).fill()
            }
        }

        storage.enumerateAttribute(.markdownImage, in: characters) { value, range, _ in
            guard let embed = value as? ImageEmbed, let image = image(for: embed) else { return }
            let fragment = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: range.location), effectiveRange: nil)
            let size = size(of: image, for: embed, in: container)
            let rect = NSRect(
                x: left,
                y: origin.y + fragment.maxY - size.height - Self.imageSpacing / 2,
                width: size.width,
                height: size.height
            )
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }

        if let blockCursor, let rect = blockCursorRect(at: blockCursor, in: container) {
            NSColor.controlAccentColor.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y), xRadius: 2, yRadius: 2).fill()
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
            let configuration = NSImage.SymbolConfiguration(pointSize: MarkdownStyler.checkboxSize, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: colors))
            guard let image = NSImage(systemSymbolName: done ? "checkmark.square.fill" : "square", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return }
            // Left-aligned, since `[x]` and `[ ]` differ in width; centered on the line vertically.
            let rect = NSRect(
                x: bounds.minX,
                y: bounds.midY - image.size.height / 2,
                width: image.size.width,
                height: image.size.height
            )
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// The block covering the character at `index`, a letter wide on an empty line or at a line end.
    private func blockCursorRect(at index: Int, in container: NSTextContainer) -> NSRect? {
        guard let storage = textStorage else { return nil }
        func font(at index: Int) -> NSFont {
            let font = index >= 0 && index < storage.length ? storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont : nil
            return font ?? .systemFont(ofSize: MarkdownStyler.baseFontSize)
        }
        func emptyWidth(_ font: NSFont) -> CGFloat {
            ("n" as NSString).size(withAttributes: [.font: font]).width
        }

        // On the empty last line (or in an empty note) the caret sits in the extra line fragment.
        guard index < storage.length else {
            let font = font(at: storage.length - 1)
            let extra = extraLineFragmentRect
            return NSRect(x: extra.minX + container.lineFragmentPadding, y: extra.minY, width: emptyWidth(font), height: font.ascender - font.descender)
        }
        let glyph = glyphIndexForCharacter(at: index)
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = location(forGlyphAt: glyph)
        let font = font(at: index)
        let isNewline = (storage.string as NSString).character(at: index) == 10
        let glyphWidth = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).width
        let width = isNewline || glyphWidth < 1 ? emptyWidth(font) : glyphWidth
        let baseline = fragment.minY + location.y
        return NSRect(x: fragment.minX + location.x, y: baseline - font.ascender, width: width, height: font.ascender - font.descender)
    }

    private func lineFragmentsRect(for characters: NSRange) -> NSRect {
        var rect = NSRect.null
        enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: characters, actualCharacterRange: nil)) { fragment, _, _, _, _ in
            rect = rect.union(fragment)
        }
        return rect
    }
}
