import SwiftUI

/// Takes keyboard focus without deactivating the app underneath Portal.
final class NotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init<Content: View>(rootView: Content) {
        // Non-activation must be set at creation, not added to an existing window.
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "Portal"
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentMinSize = NSSize(width: 280, height: 220)
        toolbarStyle = .unified

        let controller = NSHostingController(rootView: rootView)
        controller.sceneBridgingOptions = .all
        contentViewController = controller
        standardWindowButton(.zoomButton)?.isEnabled = false
        center()
        setFrameAutosaveName("PortalNote")
    }
}
