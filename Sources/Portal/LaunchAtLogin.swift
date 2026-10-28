import Combine
import ServiceManagement

@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

struct SystemLoginItemService: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// System status is authoritative. Reading settings never changes the user's login items.
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?
    private let service: any LoginItemService

    init(service: any LoginItemService) {
        self.service = service
        status = service.status
    }

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    var statusMessage: String {
        switch status {
        case .enabled: "Portal opens automatically when you log in."
        case .notRegistered: "Portal won’t open automatically when you log in."
        case .requiresApproval: "Allow Portal in System Settings → General → Login Items to finish enabling launch at login."
        case .notFound: "Install Portal in Applications and open it there before enabling launch at login."
        @unknown default: "Check Portal’s launch-at-login status in System Settings → General → Login Items."
        }
    }

    func refresh() {
        status = service.status
    }

    /// Called only by the Settings toggle, never during initialization or refresh.
    func setEnabled(_ enabled: Bool) {
        refresh()
        errorMessage = nil
        if enabled, needsApproval {
            service.openSystemSettings()
            return
        }
        guard enabled != isEnabled || (!enabled && needsApproval) else { return }
        do {
            if enabled { try service.register() }
            else { try service.unregister() }
        } catch {
            let action = enabled ? "turn on" : "turn off"
            errorMessage = "Couldn’t \(action) launch at login. \(error.localizedDescription) You can also manage Portal in System Settings → General → Login Items."
        }
        refresh()
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
