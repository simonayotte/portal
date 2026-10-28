import SwiftUI

@main
struct PortalApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Portal", id: "note") {
            ContentView(store: appDelegate.store)
        }
        .windowLevel(.floating)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 400, height: 700)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = NoteStore()

    func applicationDidBecomeActive(_ notification: Notification) {
        store.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.leaveCurrentNote()
    }
}
