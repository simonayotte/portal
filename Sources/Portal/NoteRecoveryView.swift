import SwiftUI

/// Only occupies space while an operation needs attention.
struct NoteRecoveryView: View {
    @Bindable var store: NoteStore
    @State private var confirmReload = false

    var body: some View {
        if let issue = store.issue {
            VStack(alignment: .leading, spacing: 8) {
                Label(issue.title, systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.semibold))
                Text(issue.message)
                    .font(.caption)
                    .textSelection(.enabled)
                if store.isDirty {
                    Text("Your unsaved changes are still here.")
                        .font(.caption.weight(.medium))
                }
                ViewThatFits(in: .horizontal) {
                    HStack { recoveryActions }
                    VStack(alignment: .leading) { recoveryActions }
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .confirmationDialog("Discard unsaved changes and reload from disk?", isPresented: $confirmReload) {
                Button("Discard Changes and Reload", role: .destructive) {
                    store.reloadCurrentNote(discardChanges: true)
                }
            } message: {
                Text("Save a copy first if you want to keep your version. If the file can’t be read, your changes will stay here.")
            }
        }
    }

    @ViewBuilder
    private var recoveryActions: some View {
        if store.canRetry {
            Button("Retry") { store.retry() }
        }
        if store.canEdit {
            Button("Save a Copy…", action: saveCopy)
            if store.isDirty || store.issue?.url == store.selectedID {
                Button("Reload from Disk…") {
                    if store.isDirty { confirmReload = true }
                    else { store.reloadCurrentNote() }
                }
            }
        }
    }

    private func saveCopy() {
        let panel = NSSavePanel()
        panel.title = "Save a Copy"
        panel.prompt = "Save a Copy"
        panel.message = "Your original file won’t be replaced. An existing name gets a unique suffix."
        panel.nameFieldStringValue = (store.selected?.title ?? "Note") + " (Portal copy).md"
        panel.directoryURL = store.selectedID?.deletingLastPathComponent() ?? store.vault
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.saveCopy(to: url)
    }
}
