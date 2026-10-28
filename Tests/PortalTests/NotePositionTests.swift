import SwiftUI
import Testing
@testable import Portal

@MainActor
private final class PositionFixture {
    let suite = "PortalTests.NotePosition.\(UUID().uuidString)"
    let defaults: UserDefaults
    let positions: NotePositionStore
    let view = MarkdownTextView.make()
    let scroll = PositionRestoringScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
    let coordinator: MarkdownEditor.Coordinator

    init() {
        defaults = UserDefaults(suiteName: suite)!
        positions = NotePositionStore(defaults: defaults)
        coordinator = MarkdownEditor.Coordinator(text: .constant(""), positions: positions)
        scroll.hasVerticalScroller = true
        view.frame = scroll.contentView.bounds
        scroll.documentView = view
        coordinator.attach(to: scroll)
    }

    func close() {
        coordinator.detach()
        defaults.removePersistentDomain(forName: suite)
    }

    func setPosition(_ selection: NSRange, y: CGFloat, mode: VimMode = .normal, cursor: Int? = nil) {
        view.vim.restore(selection: selection, state: .init(
            mode: mode, cursor: cursor ?? selection.location,
            anchor: selection.location
        ))
        view.updateActiveLine()
        if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
        view.sizeToFit()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

private let noteA = URL(filePath: "/fixture-vault/a.md")
private let noteB = URL(filePath: "/fixture-vault/b.md")
private let longNote = (0..<200).map { "Line \($0): a note with enough text to scroll.\n" }.joined()

private func position(_ location: Int, length: Int = 0, y: CGFloat = 0) -> NotePosition {
    NotePosition(
        selection: NSRange(location: location, length: length), scrollOrigin: NSPoint(x: 0, y: y),
        vim: .init(mode: .insert, cursor: location, anchor: location)
    )
}

@MainActor
@Test(arguments: [false, true])
func notePositionsAreIndependentEvenWithIdenticalText(identicalText: Bool) {
    let fixture = PositionFixture()
    defer { fixture.close() }
    let secondText = identicalText ? longNote : "Different note\n" + longNote

    fixture.coordinator.load(longNote, noteID: noteA)
    let selectionA = NSRange(location: 100, length: 12)
    fixture.setPosition(selectionA, y: 500, mode: .visual, cursor: 111)
    let offsetA = fixture.scroll.contentView.bounds.origin
    fixture.coordinator.load(secondText, noteID: noteB)
    #expect(fixture.view.selectedRange() == NSRange(location: 0, length: 0))
    #expect(fixture.scroll.contentView.bounds.origin == .zero)
    #expect(fixture.positions.position(for: noteA)?.selection == selectionA)

    let selectionB = NSRange(location: 250, length: 0)
    fixture.setPosition(selectionB, y: 1200, mode: .insert)
    let offsetB = fixture.scroll.contentView.bounds.origin
    fixture.coordinator.load(longNote, noteID: noteA)
    #expect(fixture.view.selectedRange() == selectionA)
    #expect(fixture.scroll.contentView.bounds.origin == offsetA)
    #expect(fixture.view.vim.mode == .visual)
    #expect((fixture.view.layoutManager as? MarkdownLayoutManager)?.blockCursor == 111)
    #expect((fixture.view.layoutManager as? MarkdownLayoutManager)?.activeLine == (longNote as NSString).paragraphRange(for: selectionA))

    fixture.coordinator.load(secondText, noteID: noteB)
    #expect(fixture.view.selectedRange() == selectionB)
    #expect(fixture.scroll.contentView.bounds.origin == offsetB)
    #expect(fixture.view.vim.mode == .insert)
    #expect((fixture.view.layoutManager as? MarkdownLayoutManager)?.blockCursor == nil)
    #expect(fixture.view.window == nil)
}

@MainActor
@Test func notePositionPersistsAcrossEditorRecreation() {
    let fixture = PositionFixture()
    defer { fixture.close() }
    fixture.coordinator.load(longNote, noteID: noteA)
    fixture.setPosition(NSRange(location: 80, length: 0), y: 850)
    let origin = fixture.scroll.contentView.bounds.origin
    fixture.coordinator.detach()

    let reopened = MarkdownEditor.Coordinator(
        text: .constant(""), positions: NotePositionStore(defaults: fixture.defaults)
    )
    defer { reopened.detach() }
    reopened.attach(to: fixture.scroll)
    reopened.load(longNote, noteID: noteA)
    #expect(fixture.view.selectedRange() == NSRange(location: 80, length: 0))
    #expect(fixture.scroll.contentView.bounds.origin == origin)
    #expect(fixture.view.vim.mode == .normal)
    #expect((fixture.view.layoutManager as? MarkdownLayoutManager)?.blockCursor == 80)
}

@MainActor
@Test func shortenedExternalReloadClampsUTF16SelectionAndScroll() {
    let fixture = PositionFixture()
    defer { fixture.close() }
    fixture.coordinator.load(longNote, noteID: noteA)
    fixture.setPosition(NSRange(location: 100, length: 20), y: 1200, mode: .insert)
    fixture.coordinator.load("a😀b", noteID: noteA)

    #expect(fixture.view.selectedRange() == NSRange(location: 4, length: 0))
    #expect(fixture.scroll.contentView.bounds.origin == .zero)
    #expect(fixture.view.vim.mode == .insert)
    #expect(fixture.view.vim.selectionState.cursor == 4)
    #expect((fixture.view.layoutManager as? MarkdownLayoutManager)?.blockCursor == nil)
    fixture.coordinator.detach()
    #expect(NotePositionStore(defaults: fixture.defaults).position(for: noteA)?.selection == NSRange(location: 4, length: 0))
}

@MainActor
@Test func sameNoteExternalReloadKeepsSelectionScrollAndVimDirection() {
    let fixture = PositionFixture()
    defer { fixture.close() }
    fixture.coordinator.load(longNote, noteID: noteA)
    let selection = NSRange(location: 100, length: 12)
    // A reversed visual selection has its block cursor at the beginning, not the end.
    fixture.view.vim.restore(selection: selection, state: .init(mode: .visual, cursor: 100, anchor: 111))
    fixture.view.updateActiveLine()
    fixture.scroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
    let origin = fixture.scroll.contentView.bounds.origin
    fixture.coordinator.load(longNote + "Externally appended\n", noteID: noteA)
    #expect(fixture.view.selectedRange() == selection)
    #expect(fixture.scroll.contentView.bounds.origin == origin)
    #expect(fixture.view.vim.selectionState == .init(mode: .visual, cursor: 100, anchor: 111))
    fixture.view.vim.feed("o")
    #expect((fixture.view.layoutManager as? MarkdownLayoutManager)?.blockCursor == 111)
}

@Test func notePositionClampingUsesUTF16AndAvoidsOverflow() {
    let length = ("a😀b" as NSString).length
    #expect(length == 4)
    #expect(position(2, length: Int.max).clamped(toUTF16Length: length).selection == NSRange(location: 2, length: 2))
    #expect(position(Int.max, length: Int.max).clamped(toUTF16Length: length).selection == NSRange(location: 4, length: 0))
    #expect(position(1, length: 3).clamped(toUTF16Length: 0).selection == NSRange(location: 0, length: 0))
    var invalid = position(-2, length: -1, y: .infinity)
    invalid.scrollOrigin.x = .nan
    let clamped = invalid.clamped(toUTF16Length: length)
    #expect(clamped.selection == NSRange(location: 0, length: 0))
    #expect(clamped.scrollOrigin == .zero)
    #expect(clamped.vim.cursor == 0)
}

@MainActor
@Test func positionHistoryPersistsAndEvictsLeastRecentlyUsedNotes() {
    let fixture = PositionFixture()
    defer { fixture.close() }
    let store = NotePositionStore(defaults: fixture.defaults, capacity: 2)
    let noteC = URL(filePath: "/fixture-vault/c.md")
    store.save(position(10), for: noteA)
    store.save(position(20), for: noteB)
    store.save(position(10), for: noteA)
    store.save(position(30), for: noteC)
    let reopened = NotePositionStore(defaults: fixture.defaults, capacity: 2)
    #expect(reopened.position(for: noteA) == position(10))
    #expect(reopened.position(for: noteB) == nil)
    #expect(reopened.position(for: noteC) == position(30))
    #expect(NotePositionStore(defaults: fixture.defaults, capacity: 1).position(for: noteA) == nil)
    #expect(reopened.position(for: URL(filePath: "/fixture-vault/sub/../c.md")) == position(30))
}

@MainActor
@Test func corruptPositionPreferencesAreIgnored() {
    let fixture = PositionFixture()
    defer { fixture.close() }
    fixture.defaults.set(Data("not json".utf8), forKey: NotePositionStore.defaultsKey)
    let store = NotePositionStore(defaults: fixture.defaults)
    #expect(store.position(for: noteA) == nil)
    store.save(position(12), for: noteA)
    #expect(NotePositionStore(defaults: fixture.defaults).position(for: noteA) == position(12))
}

@MainActor
@Test func restoreWaitsForTheInitialViewport() {
    let fixture = PositionFixture()
    defer { fixture.close() }
    fixture.positions.save(position(100, y: 900), for: noteA)
    fixture.scroll.setFrameSize(.zero)
    fixture.coordinator.load(longNote, noteID: noteA)
    fixture.scroll.setFrameSize(NSSize(width: 480, height: 240))
    fixture.scroll.layoutSubtreeIfNeeded()
    #expect(fixture.view.selectedRange() == NSRange(location: 100, length: 0))
    #expect(abs(fixture.scroll.contentView.bounds.origin.y - 900) < 1)
    #expect(fixture.view.window == nil)
}

@MainActor
@Test(arguments: [false, true])
func selectionOrScrollingPersistsAfterDebounceAndStopsOnDismantle(scrollOnly: Bool) async throws {
    let fixture = PositionFixture()
    defer { fixture.close() }
    fixture.coordinator.load(longNote, noteID: noteA)
    if scrollOnly {
        fixture.scroll.contentView.scroll(to: NSPoint(x: 0, y: 700))
    } else {
        fixture.view.vim.feed("l")
    }
    #expect(fixture.defaults.data(forKey: NotePositionStore.defaultsKey) == nil)
    // Other main-actor AppKit tests may delay the debounce task's initial scheduling.
    for _ in 0..<30 {
        if fixture.defaults.data(forKey: NotePositionStore.defaultsKey) != nil { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    let saved = NotePositionStore(defaults: fixture.defaults).position(for: noteA)
    #expect(saved?.selection == NSRange(location: scrollOnly ? 0 : 1, length: 0))
    #expect(saved?.scrollOrigin == fixture.scroll.contentView.bounds.origin)

    fixture.setPosition(NSRange(location: 60, length: 0), y: 750, mode: .insert)
    fixture.coordinator.detach()
    #expect(fixture.scroll.didLayout == nil)
    #expect(fixture.view.delegate == nil)
    fixture.defaults.removePersistentDomain(forName: fixture.suite)
    fixture.scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
    try await Task.sleep(for: .milliseconds(450))
    #expect(fixture.defaults.data(forKey: NotePositionStore.defaultsKey) == nil)
}

@MainActor
@Test func applicationLifecycleFlushesPositionWithoutWaitingForDebounce() {
    let fixture = PositionFixture()
    defer { fixture.close() }
    fixture.coordinator.load(longNote, noteID: noteA)
    fixture.setPosition(NSRange(location: 25, length: 0), y: 300, mode: .insert)
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
    #expect(NotePositionStore(defaults: fixture.defaults).position(for: noteA)?.selection == NSRange(location: 25, length: 0))
    fixture.setPosition(NSRange(location: 35, length: 0), y: 400, mode: .insert)
    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
    #expect(NotePositionStore(defaults: fixture.defaults).position(for: noteA)?.selection == NSRange(location: 35, length: 0))
}

@MainActor
private final class PositionUndoWindow: NSWindow {
    let testUndoManager = UndoManager()
    override var undoManager: UndoManager? { testUndoManager }
}

/// Exercises the focus decision without showing, activating, or making a real window key.
@MainActor
private final class PositionFocusWindow: NSWindow {
    var simulatedKeyWindow = false
    var editorFocusRequests = 0
    override var isKeyWindow: Bool { simulatedKeyWindow }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? MarkdownTextView else { return super.makeFirstResponder(responder) }
        editorFocusRequests += 1
        // Model AppKit changing selection/scroll during the first-responder transition.
        view.vim.reset()
        view.enclosingScrollView?.contentView.scroll(to: .zero)
        return true
    }
}

@MainActor
@Test(arguments: [false, true])
func initialEditorFocusRequiresKeyWindowAndPreservesPosition(isKeyWindow: Bool) {
    _ = NSApplication.shared
    let fixture = PositionFixture()
    defer { fixture.close() }
    let window = PositionFocusWindow(
        contentRect: fixture.scroll.frame, styleMask: [.borderless], backing: .buffered, defer: true
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = fixture.scroll
    window.simulatedKeyWindow = isKeyWindow
    let saved = NotePosition(
        selection: NSRange(location: 100, length: 12), scrollOrigin: NSPoint(x: 0, y: 900),
        vim: .init(mode: .visual, cursor: 100, anchor: 111)
    )
    fixture.positions.save(saved, for: noteA)
    fixture.coordinator.load(longNote, noteID: noteA)
    fixture.coordinator.load(longNote, noteID: noteA) // The initial SwiftUI update is a no-op.
    fixture.coordinator.focusInitially()
    #expect(window.editorFocusRequests == (isKeyWindow ? 1 : 0))
    #expect(fixture.view.selectedRange() == saved.selection)
    #expect(fixture.scroll.contentView.bounds.origin == saved.scrollOrigin)
    #expect(fixture.view.vim.selectionState == saved.vim)
    #expect((fixture.view.layoutManager as? MarkdownLayoutManager)?.activeLine == (longNote as NSString).paragraphRange(for: saved.selection))

    window.simulatedKeyWindow = true
    fixture.coordinator.focusInitially() // A later attempt must not steal focus.
    fixture.coordinator.load(longNote, noteID: noteB)
    #expect(window.editorFocusRequests == (isKeyWindow ? 1 : 0))
    #expect(!window.isVisible)
}

@MainActor
@Test func noteSwitchBeforeInitialFocusDoesNotStealFocus() {
    _ = NSApplication.shared
    let fixture = PositionFixture()
    defer { fixture.close() }
    let window = PositionFocusWindow(
        contentRect: fixture.scroll.frame, styleMask: [.borderless], backing: .buffered, defer: true
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = fixture.scroll
    window.simulatedKeyWindow = true
    fixture.coordinator.load(longNote, noteID: noteA)
    fixture.coordinator.load(longNote, noteID: noteB)
    fixture.coordinator.focusInitially()
    #expect(window.editorFocusRequests == 0)
    #expect(!window.isVisible)
}

@MainActor
@Test func identicalTextNoteSwitchClearsUndoWithoutTakingFocus() throws {
    _ = NSApplication.shared
    let fixture = PositionFixture()
    defer { fixture.close() }
    let window = PositionUndoWindow(
        contentRect: fixture.scroll.frame, styleMask: [.borderless], backing: .buffered, defer: true
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = fixture.scroll
    fixture.coordinator.load(longNote, noteID: noteA)
    let undo = try #require(fixture.view.undoManager)
    let responder = window.firstResponder
    fixture.view.vim.feed("i")
    undo.registerUndo(withTarget: fixture.view) { $0.string = "old note" }
    #expect(undo.canUndo)
    fixture.coordinator.load(longNote, noteID: noteA)
    #expect(undo.canUndo)
    #expect(fixture.view.vim.mode == .insert)

    fixture.coordinator.load(longNote, noteID: noteB)
    #expect(!undo.canUndo)
    #expect(!undo.canRedo)
    #expect(fixture.view.vim.mode == .normal)
    #expect(window.firstResponder === responder)
    #expect(!window.isVisible)
}
