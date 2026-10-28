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
        isOpaque = false
        backgroundColor = .clear
        titlebarAppearsTransparent = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentMinSize = NSSize(width: 280, height: 220)
        toolbarStyle = .unified

        let controller = NSHostingController(rootView: rootView)
        controller.sceneBridgingOptions = .all
        contentViewController = controller
        standardWindowButton(.zoomButton)?.isEnabled = false
        setTrafficLightsHidden(true)
        center()
        setFrameAutosaveName("PortalNote")
    }

    override func becomeKey() {
        super.becomeKey()
        setTrafficLightsHidden(false)
    }

    override func resignKey() {
        super.resignKey()
        setTrafficLightsHidden(true)
    }

    private func setTrafficLightsHidden(_ hidden: Bool) {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for button in buttons {
            standardWindowButton(button)?.isHidden = hidden
        }
    }
}

/// Shared surface for the editor and its command palettes.
struct NoteBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WindowBackground()
            .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.15))
            .overlay(
                colorScheme == .dark ? Color.black.opacity(0.2) : Color.white.opacity(0.35)
            )
    }
}

/// Native behind-window blur, kept active even while Portal leaves the other app active.
struct WindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
