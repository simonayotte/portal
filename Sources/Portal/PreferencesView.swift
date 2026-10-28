import SwiftUI

struct PreferencesView: View {
    @ObservedObject var preferences: PortalPreferences
    @StateObject private var login: LaunchAtLogin
    @Environment(\.scenePhase) private var scenePhase

    init(preferences: PortalPreferences, login: LaunchAtLogin = LaunchAtLogin(service: SystemLoginItemService())) {
        self.preferences = preferences
        _login = StateObject(wrappedValue: login)
    }

    var body: some View {
        Form {
            Section("Editor") {
                LabeledContent("Text size") {
                    Stepper(value: $preferences.editorTextSize, in: EditorTypography.textSizeRange, step: 1) {
                        Text("\(preferences.editorTextSize, format: .number.precision(.fractionLength(0))) pt")
                            .monospacedDigit()
                            .frame(minWidth: 48, alignment: .trailing)
                    }
                    .accessibilityLabel("Editor text size")
                }
            }
            Section {
                Slider(value: $preferences.backgroundOpacity, in: PortalPreferences.backgroundOpacityRange) {
                    Text("Background opacity")
                } minimumValueLabel: {
                    Text("Less")
                } maximumValueLabel: {
                    Text("More")
                }
            } header: {
                Text("Background")
            } footer: {
                Text("Adjusts the solid layer over the translucent material in the editor and command palette.")
            }
            Section {
                Toggle("Launch at login", isOn: Binding(get: { login.isEnabled }, set: login.setEnabled))
                Text(login.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = login.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if login.needsApproval || login.errorMessage != nil || login.status == .notFound {
                    Button("Open Login Items Settings…", action: login.openSystemSettings)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { login.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { login.refresh() }
        }
    }
}
