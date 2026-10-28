import AppKit
import Testing
@testable import Portal

@Suite(.serialized)
@MainActor
struct EditorFindTests {
    @Test func usesNativeIncrementalFindBar() {
        _ = NSApplication.shared
        let view = MarkdownTextView.make()
        #expect(view.usesFindBar)
        #expect(!view.usesFindPanel)
        #expect(view.isIncrementalSearchingEnabled)
    }

    @Test func findCommandOpensAndFocusesNativeSearchField() throws {
        let editor = FindEditor()
        defer { editor.close() }
        #expect(editor.panel.makeFirstResponder(editor.view))

        #expect(editor.panel.performKeyEquivalent(with: key("f", modifiers: .command)))
        #expect(editor.scrollView.isFindBarVisible)
        let field = try #require(searchField(in: editor.scrollView.findBarView))
        #expect(field.currentEditor() === editor.panel.firstResponder)
        #expect(editor.panel.performKeyEquivalent(with: key("f", modifiers: .command)))
        #expect(field.currentEditor() === editor.panel.firstResponder)
        #expect(editor.panel.styleMask.contains(.nonactivatingPanel))
        #expect(!editor.panel.isVisible)
    }

    @Test func typedSearchUsesNativeFieldAndFindDispatch() throws {
        let editor = FindEditor()
        defer { editor.close() }
        editor.view.string = "before portal-find-typed after"
        editor.view.find(.showFindInterface)
        let field = try #require(searchField(in: editor.scrollView.findBarView))
        let fieldEditor = try #require(field.currentEditor() as? NSTextView)
        fieldEditor.selectAll(nil)
        fieldEditor.insertText("portal-find-typed", replacementRange: fieldEditor.selectedRange())

        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(editor.panel.performKeyEquivalent(with: key("g", modifiers: .command)))
        #expect(editor.view.selectedRange() == NSRange(location: 7, length: 17))
        #expect(field.currentEditor() === editor.panel.firstResponder)
    }

    @Test func replacingNoteInvalidatesNativeSearchState() throws {
        let editor = FindEditor()
        defer { editor.close() }
        editor.view.replaceNoteContents(with: "portal-find-token old portal-find-token")
        editor.view.setSelectedRange(NSRange(location: 0, length: 17))
        editor.view.find(.setSearchString)
        editor.view.find(.showFindInterface)

        editor.view.replaceNoteContents(with: "new portal-find-token")
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        editor.view.find(.nextMatch)
        #expect(editor.view.selectedRange() == NSRange(location: 4, length: 17))
        editor.view.replaceNoteContents(with: "no matches")
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        editor.view.find(.nextMatch)
        #expect(editor.view.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func modelDrivenNoteReplacementEmitsNativeChangeNotifications() {
        let editor = FindEditor()
        defer { editor.close() }
        let observer = TextChangeObserver()
        editor.view.delegate = observer
        editor.view.replaceNoteContents(with: "new note")
        #expect(observer.willChangeCount == 1)
        #expect(observer.didChangeCount == 1)
        #expect(editor.view.string == "new note")
    }

    @Test func findCommandsDoNotHijackUnrelatedTextFields() {
        let editor = FindEditor()
        defer { editor.close() }
        editor.view.find(.showFindInterface)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let root = NSView(frame: editor.scrollView.frame)
        root.addSubview(editor.scrollView)
        root.addSubview(field)
        editor.panel.contentView = root
        editor.panel.makeFirstResponder(field)
        #expect(!editor.view.performKeyEquivalent(with: key("f", modifiers: .command)))
        #expect(!editor.view.performKeyEquivalent(with: key("g", modifiers: .command)))
    }

    @Test func nextAndPreviousCommandsSearchOnlyCurrentNote() throws {
        let editor = FindEditor()
        defer { editor.close() }
        editor.view.string = "portal-find-token other portal-find-token last portal-find-token"
        editor.view.setSelectedRange(NSRange(location: 0, length: 17))
        editor.view.find(.setSearchString)
        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        editor.view.find(.showFindInterface)
        let field = try #require(searchField(in: editor.scrollView.findBarView))
        #expect(field.stringValue == "portal-find-token")
        let fieldEditor = try #require(field.currentEditor())
        fieldEditor.selectedRange = NSRange(location: 3, length: 2)

        editor.view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(editor.panel.performKeyEquivalent(with: key("g", modifiers: .command)))
        #expect(editor.view.selectedRange() == NSRange(location: 0, length: 17))
        #expect(field.currentEditor() === editor.panel.firstResponder)
        #expect(fieldEditor.selectedRange == NSRange(location: 3, length: 2))
        #expect(editor.panel.performKeyEquivalent(with: key("g", modifiers: .command)))
        #expect(editor.view.selectedRange() == NSRange(location: 24, length: 17))
        #expect(editor.panel.performKeyEquivalent(with: key("g", modifiers: [.command, .shift])))
        #expect(editor.view.selectedRange() == NSRange(location: 0, length: 17))
        #expect(field.currentEditor() === editor.panel.firstResponder)
        #expect(editor.view.closeFindBar())
        #expect(editor.panel.performKeyEquivalent(with: key("g", modifiers: .command)))
        #expect(editor.view.selectedRange() == NSRange(location: 24, length: 17))
        #expect(!editor.scrollView.isFindBarVisible)
        #expect(editor.panel.firstResponder === editor.view)
        #expect(!editor.panel.isVisible)
    }

    @Test func escapeClosesFindAndRestoresEditorFocus() throws {
        let editor = FindEditor()
        defer { editor.close() }
        editor.view.find(.showFindInterface)
        let field = try #require(searchField(in: editor.scrollView.findBarView))
        let fieldEditor = try #require(field.currentEditor())
        fieldEditor.interpretKeyEvents([key("\u{1b}", keyCode: 53)])

        #expect(!editor.scrollView.isFindBarVisible)
        #expect(editor.panel.firstResponder === editor.view)
    }

    @Test func escapeInEditorClosesFindBeforeVim() {
        let editor = FindEditor()
        defer { editor.close() }
        editor.view.vim.feed("i")
        editor.view.find(.showFindInterface)
        editor.panel.makeFirstResponder(editor.view)
        editor.view.keyDown(with: key("\u{1b}", keyCode: 53))
        #expect(!editor.scrollView.isFindBarVisible)
        #expect(editor.view.vim.mode == .insert)
        editor.view.keyDown(with: key("\u{1b}", keyCode: 53))
        #expect(editor.view.vim.mode == .normal)
    }

    @Test func paletteExposesFindWithShortcut() throws {
        let action = try #require(MarkdownAction.all.first { $0.title == "Find in Note" })
        #expect(action.shortcut == "⌘F")
        let editor = FindEditor()
        defer { editor.close() }
        let controller = EditorController()
        controller.textView = editor.view
        controller.perform(action)
        #expect(editor.scrollView.isFindBarVisible)
        let field = try #require(searchField(in: editor.scrollView.findBarView))
        #expect(field.currentEditor() === editor.panel.firstResponder)
        editor.view.closeFindBar()
        controller.findInNote()
        #expect(editor.scrollView.isFindBarVisible)
        #expect(field.currentEditor() === editor.panel.firstResponder)
    }

    private func key(_ characters: String, modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        )!
    }

    private func searchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        return view.subviews.lazy.compactMap { searchField(in: $0) }.first
    }
}

@MainActor
private final class TextChangeObserver: NSObject, NSTextViewDelegate {
    var willChangeCount = 0
    var didChangeCount = 0

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        willChangeCount += 1
        return true
    }

    func textDidChange(_ notification: Notification) {
        didChangeCount += 1
    }
}

/// Never ordered onscreen, activated, or connected to a vault or preferences.
@MainActor
private struct FindEditor {
    let panel: NSPanel
    let scrollView: NSScrollView
    let view: MarkdownTextView
    private let findPasteboard: [(NSPasteboard.PasteboardType, Data)]

    init() {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard(name: .find)
        findPasteboard = (pasteboard.types ?? []).compactMap { type in
            pasteboard.data(forType: type).map { (type, $0) }
        }
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.findBarPosition = .aboveContent
        view = MarkdownTextView.make()
        view.frame = scrollView.bounds
        scrollView.documentView = view
        panel.contentView = scrollView
        panel.makeFirstResponder(view)
    }

    func close() {
        panel.close()
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents()
        for (type, data) in findPasteboard { pasteboard.setData(data, forType: type) }
    }
}
