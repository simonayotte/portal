import SwiftUI

struct ContentView: View {
    @Bindable var store: NoteStore

    var body: some View {
        MarkdownEditor(text: $store.text)
            .overlay(alignment: .topLeading) {
                if store.text.isEmpty {
                    Text("Start writing...")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, MarkdownEditor.inset.width + 5)
                        .padding(.top, MarkdownEditor.inset.height)
                        .allowsHitTesting(false)
                }
            }
            .frame(minWidth: 280, minHeight: 220)
            .containerBackground(.thickMaterial, for: .window)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(store.selected?.title ?? "Untitled")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Commands", systemImage: "command") {}
                    Button("Copy", systemImage: "rectangle.portrait.on.rectangle.portrait.angled") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.text, forType: .string)
                    }
                    Button("New Note", systemImage: "plus") { store.create() }
                        .keyboardShortcut("n")
                }
            }
            .background(FloatingWindowConfigurator())
    }
}

/// Lets the window follow you across Spaces and over full-screen apps.
private struct FloatingWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
