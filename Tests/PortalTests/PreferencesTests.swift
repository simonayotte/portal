import SwiftUI
import Testing
@testable import Portal

@MainActor
func withPreferenceDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suite = "PortalTests.preferences.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

@MainActor
@Test func preferencesPreserveTheApprovedDefaults() {
    withPreferenceDefaults { defaults in
        let preferences = PortalPreferences(defaults: defaults)
        #expect(preferences.editorTextSize == 16)
        #expect(preferences.backgroundOpacity == 0.15)
        #expect(defaults.object(forKey: PortalPreferences.Key.editorTextSize) == nil)
        #expect(defaults.object(forKey: PortalPreferences.Key.backgroundOpacity) == nil)
    }
}

@MainActor
@Test func preferencesPersistChanges() {
    withPreferenceDefaults { defaults in
        let preferences = PortalPreferences(defaults: defaults)
        preferences.editorTextSize = 21
        preferences.backgroundOpacity = 0.65
        let reloaded = PortalPreferences(defaults: defaults)
        #expect(reloaded.editorTextSize == 21)
        #expect(reloaded.backgroundOpacity == 0.65)
    }
}

@MainActor
@Test(arguments: [-100.0, 0, 12, 16, 28, 100, .nan, .infinity, -.infinity])
func preferencesValidateAndRepairPersistedTextSize(_ value: Double) {
    withPreferenceDefaults { defaults in
        defaults.set(value, forKey: PortalPreferences.Key.editorTextSize)
        let preferences = PortalPreferences(defaults: defaults)
        let expected = value.isFinite ? min(max(value, 12), 28) : 16
        #expect(preferences.editorTextSize == expected)
        #expect(defaults.double(forKey: PortalPreferences.Key.editorTextSize) == expected)
        preferences.editorTextSize = value
        #expect(preferences.editorTextSize == expected)
    }
}

@MainActor
@Test(arguments: [-100.0, 0, 0.15, 0.7, 1, 100, .nan, .infinity, -.infinity])
func preferencesValidateAndRepairPersistedOpacity(_ value: Double) {
    withPreferenceDefaults { defaults in
        defaults.set(value, forKey: PortalPreferences.Key.backgroundOpacity)
        let preferences = PortalPreferences(defaults: defaults)
        let expected = value.isFinite ? min(max(value, 0), 1) : 0.15
        #expect(preferences.backgroundOpacity == expected)
        #expect(defaults.double(forKey: PortalPreferences.Key.backgroundOpacity) == expected)
        preferences.backgroundOpacity = value
        #expect(preferences.backgroundOpacity == expected)
    }
}

@MainActor
@Test func preferencesRejectWrongPersistedTypes() {
    withPreferenceDefaults { defaults in
        for value: Any in ["24", true, [1, 2], Data([0])] {
            defaults.set(value, forKey: PortalPreferences.Key.editorTextSize)
            defaults.set(value, forKey: PortalPreferences.Key.backgroundOpacity)
            let preferences = PortalPreferences(defaults: defaults)
            #expect(preferences.editorTextSize == 16)
            #expect(preferences.backgroundOpacity == 0.15)
        }
    }
}

@MainActor
@Test func preferencesPublishBothAppearanceChanges() {
    withPreferenceDefaults { defaults in
        let preferences = PortalPreferences(defaults: defaults)
        var changes = 0
        let subscription = preferences.objectWillChange.sink { changes += 1 }
        preferences.editorTextSize = 20
        preferences.backgroundOpacity = 0.8
        #expect(changes == 2)
        withExtendedLifetime(subscription) {}
    }
}

@MainActor
@Test func typographyDefaultsMatchEveryApprovedFontSize() throws {
    let typography = EditorTypography()
    #expect(typography.baseFont.pointSize == 16)
    #expect(typography.monoFont.pointSize == 15)
    #expect((1...6).map { typography.headingSize(level: $0) } == [28, 23, 20, 18, 17, 16])
    let storage = NSTextStorage(string: "# Heading\nbody `code`\n")
    MarkdownStyler.style(storage)
    #expect((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 28)
    let body = (storage.string as NSString).range(of: "body").location
    let code = (storage.string as NSString).range(of: "code").location
    #expect((storage.attribute(.font, at: body, effectiveRange: nil) as? NSFont)?.pointSize == 16)
    #expect((storage.attribute(.font, at: code, effectiveRange: nil) as? NSFont)?.pointSize == 15)
    let paragraph = try #require(storage.attribute(.paragraphStyle, at: body, effectiveRange: nil) as? NSParagraphStyle)
    #expect(paragraph.lineSpacing == 3)
    #expect(paragraph.defaultTabInterval == 24)
}

@MainActor
@Test(arguments: [12.0, 20, 28])
func typographyScalesMarkdownFontsAndParagraphLayout(_ size: Double) throws {
    let source = "---\ntitle: Test\n---\n# Heading\n## Two\n### Three\n#### Four\n##### Five\n###### Six\nbody **bold** *italic* `inline`\n> quote\n- [ ] task\n```swift\nlet code = 1\n```\n| First | Second |\n| --- | --- |\n| Cell | Other |\n"
    let original = NSTextStorage(string: source)
    let scaled = NSTextStorage(string: source)
    MarkdownStyler.style(original)
    MarkdownStyler.style(scaled, typography: EditorTypography(textSize: size))
    let scale = size / 16
    let taskRange = (source as NSString).lineRange(for: (source as NSString).range(of: "- [ ] task"))
    for index in 0..<original.length {
        let originalFont = try #require(original.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
        let scaledFont = try #require(scaled.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
        #expect(abs(scaledFont.pointSize - originalFont.pointSize * scale) < 0.001)
        let originalParagraph = try #require(original.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
        let scaledParagraph = try #require(scaled.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
        #expect(abs(scaledParagraph.lineSpacing - originalParagraph.lineSpacing * scale) < 0.001)
        #expect(abs(scaledParagraph.defaultTabInterval - originalParagraph.defaultTabInterval * scale) < 0.001)
        #expect(abs(scaledParagraph.paragraphSpacingBefore - originalParagraph.paragraphSpacingBefore * scale) < 0.001)
        #expect(abs(scaledParagraph.paragraphSpacing - originalParagraph.paragraphSpacing * scale) < 0.001)
        // List indents track actual marker widths, including the system font's optical sizing.
        if !NSLocationInRange(index, taskRange) {
            #expect(abs(scaledParagraph.headIndent - originalParagraph.headIndent * scale) < 0.001)
        }
    }
    let taskParagraph = try #require(scaled.attribute(.paragraphStyle, at: taskRange.location, effectiveRange: nil) as? NSParagraphStyle)
    let markerWidth = NSAttributedString(string: "[x] ", attributes: MarkdownStyler.baseAttributes(for: EditorTypography(textSize: size))).size().width
    #expect(abs(taskParagraph.headIndent - markerWidth - 6 * scale) < 0.001)
    #expect(original.string == scaled.string)
}

@MainActor
@Test func editorAppliesLivePreferencesWithoutReplacingItsTextView() throws {
    try withPreferenceDefaults { defaults in
        _ = NSApplication.shared
        let preferences = PortalPreferences(defaults: defaults)
        let controller = EditorController()
        let host = NSHostingView(rootView: MarkdownEditor(text: .constant("# Heading\nBody"), noteID: nil, controller: controller, preferences: preferences))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
        let textView = try #require(controller.textView)
        textView.setSelectedRange(NSRange(location: 11, length: 2))
        let selection = textView.selectedRanges
        preferences.editorTextSize = 22
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()
        #expect(controller.textView === textView)
        #expect(textView.typography.textSize == 22)
        #expect(textView.string == "# Heading\nBody")
        #expect(textView.selectedRanges == selection)
        withExtendedLifetime(host) {}
    }
}

@MainActor
@Test(arguments: [12.0, 24, 28])
func changingTextSizePreservesDocumentUndoSelectionAndScroll(_ size: Double) throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let scroll = NSScrollView(frame: window.contentView!.bounds)
    let textView = MarkdownTextView.make()
    scroll.documentView = textView
    window.contentView = scroll
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 4000)
    let source = (0..<150).map { "Line \($0): some **Markdown** text" }.joined(separator: "\n")
    textView.string = source
    textView.restyle()
    textView.updateActiveLine()
    let undo = try #require(textView.undoManager)
    undo.beginUndoGrouping()
    textView.replace(NSRange(location: 0, length: 0), with: "Edited ")
    undo.endUndoGrouping()
    #expect(undo.canUndo)
    textView.setSelectedRange(NSRange(location: 40, length: 4))
    textView.updateActiveLine()
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 250))
    let content = textView.string
    let selection = textView.selectedRanges
    let origin = scroll.contentView.bounds.origin
    let activeLine = (textView.layoutManager as? MarkdownLayoutManager)?.activeLine
    let mode = textView.vim.mode

    textView.updateTextSize(size)

    #expect(textView.string == content)
    #expect(textView.selectedRanges == selection)
    #expect(scroll.contentView.bounds.origin == origin)
    #expect((textView.layoutManager as? MarkdownLayoutManager)?.activeLine == activeLine)
    #expect(textView.vim.mode == mode)
    #expect((textView.typingAttributes[.font] as? NSFont)?.pointSize == CGFloat(size))
    #expect(undo.canUndo)
    undo.undo()
    #expect(textView.string == source)
}
