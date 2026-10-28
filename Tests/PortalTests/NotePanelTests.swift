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
    #expect(!panel.isOpaque)
    #expect(panel.backgroundColor == .clear)
    #expect(panel.titlebarAppearsTransparent)
    #expect(!panel.hidesOnDeactivate)
    #expect(!panel.isReleasedWhenClosed)
    #expect(panel.level == .floating)
    #expect(panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary]))
    #expect(panel.contentViewController is NSHostingController<EmptyView>)
    #expect(panel.standardWindowButton(.zoomButton)?.isEnabled == false)
}

@MainActor
@Test func notePanelOnlyShowsTrafficLightsWhileFocused() {
    _ = NSApplication.shared
    let panel = NotePanel(rootView: EmptyView())
    defer { panel.close() }
    let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    for button in buttons {
        #expect(panel.standardWindowButton(button)?.isHidden == true)
    }
    panel.becomeKey()
    for button in buttons {
        #expect(panel.standardWindowButton(button)?.isHidden == false)
    }
    panel.resignKey()
    for button in buttons {
        #expect(panel.standardWindowButton(button)?.isHidden == true)
    }
    panel.becomeKey()
    for button in buttons {
        #expect(panel.standardWindowButton(button)?.isHidden == false)
    }
    panel.resignKey()
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

@MainActor
@Test(arguments: [ColorScheme.light, .dark])
func noteBackgroundBlursBehindTheWindowWithoutActivation(_ colorScheme: ColorScheme) throws {
    _ = NSApplication.shared
    let panel = NotePanel(rootView: NoteBackground().environment(\.colorScheme, colorScheme))
    defer { panel.close() }
    let content = try #require(panel.contentView)
    content.layoutSubtreeIfNeeded()

    func findMaterial(in view: NSView) -> NSVisualEffectView? {
        if let material = view as? NSVisualEffectView { return material }
        return view.subviews.lazy.compactMap { findMaterial(in: $0) }.first
    }

    let material = try #require(findMaterial(in: content))
    #expect(material.material == .hudWindow)
    #expect(material.blendingMode == .behindWindow)
    #expect(material.state == .active)
}
