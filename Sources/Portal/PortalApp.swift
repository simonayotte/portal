import Carbon.HIToolbox
import SwiftUI

@main
struct PortalApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Portal", id: "note") {
            NoteWindow(appDelegate: appDelegate)
        }
        .windowLevel(.floating)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 400, height: 700)
    }
}

/// Hands the scene's `openWindow` action to the app delegate so the menu bar item can reopen a closed note.
private struct NoteWindow: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(store: appDelegate.store)
            .onAppear { appDelegate.openNote = { openWindow(id: "note") } }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = NoteStore()
    var openNote: (() -> Void)?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private lazy var hotKey = GlobalHotKey { [unowned self] in toggleNote() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "app.background.dotted", accessibilityDescription: "Portal")
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        hotKey.register(Shortcut.saved)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        store.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.leaveCurrentNote()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard NSApp.currentEvent?.type == .rightMouseUp else { return toggleNote() }
        let menu = NSMenu()
        let shortcutTitle = Shortcut.saved.map { "Toggle Shortcut: \($0)…" } ?? "Set Toggle Shortcut…"
        menu.addItem(withTitle: shortcutTitle, action: #selector(recordShortcut), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Portal", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// Hides Portal when any of its windows is on screen, otherwise brings the note forward and focuses it.
    private func toggleNote() {
        let isShowing = !NSApp.isHidden && NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
        if isShowing {
            NSApp.hide(nil)
        } else {
            NSApp.unhide(nil)
            NSApp.activate()
            openNote?()
        }
    }

    @objc private func recordShortcut() {
        hotKey.register(nil)
        let alert = NSAlert()
        alert.messageText = "Press a shortcut to toggle Portal"
        alert.informativeText = "Include ⌘, ⌥ or ⌃. Press Delete to remove the shortcut, Esc to cancel."
        alert.addButton(withTitle: "Cancel")
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape: NSApp.stopModal()
            case kVK_Delete: Shortcut.saved = nil; NSApp.stopModal()
            default:
                guard let shortcut = Shortcut(event: event) else { return nil }
                Shortcut.saved = shortcut
                NSApp.stopModal()
            }
            return nil
        }
        NSApp.activate()
        alert.runModal()
        monitor.map(NSEvent.removeMonitor)
        hotKey.register(Shortcut.saved)
    }
}
