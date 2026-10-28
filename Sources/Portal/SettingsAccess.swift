import SwiftUI

/// Bridges SwiftUI's Settings action to the accessory app's status menu and local shortcut.
@MainActor
final class SettingsAccess {
    static let shared = SettingsAccess()
    var openSettings: (() -> Void)?
    private var keyMonitor: Any?

    func show() {
        NSApp.activate()
        // SwiftUI opens/orders Settings in front; its scene shares the note panel's floating level.
        openSettings?()
    }

    func installShortcut() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window?.isKeyWindow == true,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "," else { return event }
            SettingsAccess.shared.show()
            return nil
        }
    }

    func removeShortcut() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

struct SettingsActionBridge: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { SettingsAccess.shared.openSettings = { openSettings() } }
    }
}
