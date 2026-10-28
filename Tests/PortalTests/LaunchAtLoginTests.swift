import Foundation
import ServiceManagement
import SwiftUI
import Testing
@testable import Portal

@MainActor
private final class FakeLoginItemService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var registeredStatus: SMAppService.Status = .enabled
    var registrationError: Error?
    var unregistrationError: Error?
    var registerCalls = 0
    var unregisterCalls = 0
    var settingsCalls = 0

    func register() throws {
        registerCalls += 1
        if let registrationError { throw registrationError }
        status = registeredStatus
    }

    func unregister() throws {
        unregisterCalls += 1
        if let unregistrationError { throw unregistrationError }
        status = .notRegistered
    }

    func openSystemSettings() { settingsCalls += 1 }
}

@MainActor
@Test(arguments: [SMAppService.Status.notRegistered, .enabled, .requiresApproval, .notFound])
func loginItemReadsTruthfulStatusWithoutChangingRegistration(_ status: SMAppService.Status) {
    let service = FakeLoginItemService()
    service.status = status
    let login = LaunchAtLogin(service: service)
    login.refresh()
    #expect(login.status == status)
    #expect(login.isEnabled == (status == .enabled))
    #expect(login.needsApproval == (status == .requiresApproval))
    #expect(!login.statusMessage.isEmpty)
    #expect(service.registerCalls == 0)
    #expect(service.unregisterCalls == 0)
    #expect(service.settingsCalls == 0)
}

@MainActor
@Test func preferencesFormDoesNotChangeLoginItems() {
    withPreferenceDefaults { defaults in
        _ = NSApplication.shared
        let service = FakeLoginItemService()
        service.status = .requiresApproval
        let login = LaunchAtLogin(service: service)
        let host = NSHostingView(rootView: PreferencesView(preferences: PortalPreferences(defaults: defaults), login: login))
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 600)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == 440)
        #expect(host.fittingSize.height >= 250)
        #expect(host.fittingSize.height <= 800)
        #expect(service.registerCalls == 0)
        #expect(service.unregisterCalls == 0)
        #expect(service.settingsCalls == 0)
    }
}

@MainActor
@Test func loginItemRegistersAndUnregistersOnlyOnUserAction() {
    let service = FakeLoginItemService()
    let login = LaunchAtLogin(service: service)
    login.setEnabled(true)
    #expect(login.isEnabled)
    #expect(service.registerCalls == 1)
    #expect(login.errorMessage == nil)
    login.setEnabled(true)
    #expect(service.registerCalls == 1)
    login.setEnabled(false)
    #expect(!login.isEnabled)
    #expect(service.unregisterCalls == 1)
    #expect(login.errorMessage == nil)
}

@MainActor
@Test func loginItemReportsRegistrationErrorWithoutPretendingItIsEnabled() {
    let service = FakeLoginItemService()
    service.registrationError = NSError(domain: "FakeLogin", code: 1, userInfo: [NSLocalizedDescriptionKey: "Permission denied."])
    let login = LaunchAtLogin(service: service)
    login.setEnabled(true)
    #expect(!login.isEnabled)
    #expect(login.errorMessage?.contains("Permission denied.") == true)
    #expect(login.errorMessage?.contains("System Settings") == true)
    service.registrationError = nil
    login.setEnabled(true)
    #expect(login.isEnabled)
    #expect(login.errorMessage == nil)
}

@MainActor
@Test func loginItemReportsUnregistrationErrorAndKeepsActualEnabledStatus() {
    let service = FakeLoginItemService()
    service.status = .enabled
    service.unregistrationError = NSError(domain: "FakeLogin", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not remove item."])
    let login = LaunchAtLogin(service: service)
    login.setEnabled(false)
    #expect(login.isEnabled)
    #expect(login.errorMessage?.contains("Could not remove item.") == true)
    #expect(service.unregisterCalls == 1)
}

@MainActor
@Test func loginItemRequiresApprovalAndOpensSettingsOnlyOnUserAction() {
    let service = FakeLoginItemService()
    service.registeredStatus = .requiresApproval
    let login = LaunchAtLogin(service: service)
    login.setEnabled(true)
    #expect(!login.isEnabled)
    #expect(login.needsApproval)
    #expect(login.statusMessage.contains("Allow Portal"))
    #expect(login.errorMessage == nil)
    #expect(service.settingsCalls == 0)
    login.openSystemSettings()
    #expect(service.settingsCalls == 1)
    login.setEnabled(true)
    #expect(service.registerCalls == 1)
    #expect(service.settingsCalls == 2)
    service.status = .enabled
    login.refresh()
    #expect(login.isEnabled)
    #expect(!login.needsApproval)
    #expect(service.unregisterCalls == 0)
}

@MainActor
@Test func loginItemRefreshReflectsExternalChangesWithoutWrites() {
    let service = FakeLoginItemService()
    service.status = .enabled
    let login = LaunchAtLogin(service: service)
    service.status = .requiresApproval
    login.refresh()
    #expect(!login.isEnabled)
    #expect(login.needsApproval)
    #expect(service.registerCalls == 0)
    #expect(service.unregisterCalls == 0)
}
