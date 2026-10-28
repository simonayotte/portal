import SwiftUI
import Testing
@testable import Portal

@MainActor
@Test func notePanelIsConfiguredForNonactivatingInput() {
    _ = NSApplication.shared
    let panel = NotePanel(rootView: EmptyView())
    defer { panel.close() }

    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(panel.canBecomeKey)
    #expect(!panel.canBecomeMain)
    #expect(!panel.hidesOnDeactivate)
    #expect(!panel.isReleasedWhenClosed)
    #expect(panel.level == .floating)
    #expect(panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary]))
    #expect(panel.contentViewController is NSHostingController<EmptyView>)
    #expect(panel.standardWindowButton(.zoomButton)?.isEnabled == false)
}

@MainActor
@Test func notePanelKeepsSwiftUIToolbars() throws {
    _ = NSApplication.shared
    let panel = NotePanel(rootView: Text("Note").toolbar {
        ToolbarItem(placement: .primaryAction) {
            Button("Create Note") {}
                .keyboardShortcut("n")
        }
    })
    defer { panel.close() }
    panel.contentView?.layoutSubtreeIfNeeded()

    let toolbar = try #require(panel.toolbar)
    #expect(!toolbar.items.isEmpty)
    #expect(panel.styleMask.contains(.nonactivatingPanel))
}
