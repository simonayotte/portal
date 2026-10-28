import Carbon.HIToolbox
import SwiftUI

@main
struct PortalApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Settings { PreferencesView(preferences: .shared) }
            .windowLevel(.floating)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = NoteStore()
    private lazy var notePanel: NotePanel = {
        let panel = NotePanel(rootView: ContentView(store: store))
        panel.delegate = self
        return panel
    }()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private lazy var hotKey = GlobalHotKey { [unowned self] in toggleNote() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        notePanel.makeKeyAndOrderFront(nil)
        SettingsAccess.shared.installShortcut()
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        notePanel.makeKeyAndOrderFront(nil)
        return true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        store.refresh()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store.leaveCurrentNote() else {
            notePanel.makeKeyAndOrderFront(nil)
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        SettingsAccess.shared.removeShortcut()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard NSApp.currentEvent?.type == .rightMouseUp else { return toggleNote() }
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        let shortcutTitle = Shortcut.saved.map { "Toggle Shortcut: \($0)…" } ?? "Set Toggle Shortcut…"
        menu.addItem(withTitle: shortcutTitle, action: #selector(recordShortcut), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Portal", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// Toggles the note without deactivating the app behind it.
    private func toggleNote() {
        if notePanel.isVisible {
            notePanel.orderOut(nil)
        } else {
            notePanel.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func openSettings() {
        SettingsAccess.shared.show()
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
