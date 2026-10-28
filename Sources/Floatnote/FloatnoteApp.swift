import SwiftUI

@main
struct FloatnoteApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Floatnote", id: "note") {
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

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
    }
}
