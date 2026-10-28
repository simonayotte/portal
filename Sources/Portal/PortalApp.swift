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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "app.background.dotted", accessibilityDescription: "Portal")
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Quit Portal", action: #selector(NSApplication.terminate), keyEquivalent: "q")
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        } else if NSApp.isActive, NSApp.keyWindow != nil {
            NSApp.hide(nil)
        } else {
            NSApp.activate()
            openNote?()
        }
    }
}
