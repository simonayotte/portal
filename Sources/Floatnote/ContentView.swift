import SwiftUI

private enum ToolbarAction: String, CaseIterable, Identifiable {
    case actionPanel = "Action Panel"
    case browseNotes = "Browse Notes"
    case createNote = "Create Note"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .actionPanel: "command"
        case .browseNotes: "rectangle.portrait.on.rectangle.portrait.angled"
        case .createNote: "plus"
        }
    }

    var key: Character {
        switch self {
        case .actionPanel: "k"
        case .browseNotes: "p"
        case .createNote: "n"
        }
    }
}

struct ContentView: View {
    @Bindable var store: NoteStore
    @State private var tooltip: ToolbarAction?
    @State private var hoverTask: Task<Void, Never>?
    @State private var vimMode = VimMode.normal

    var body: some View {
        MarkdownEditor(text: $store.text, vimMode: $vimMode)
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
            .overlay(alignment: .topTrailing) {
                if let tooltip {
                    Tooltip(action: tooltip)
                        .padding(.top, 6)
                        .padding(.trailing, 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .topTrailing)))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                VimModePill(mode: vimMode)
                    .padding(12)
                    .allowsHitTesting(false)
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
                    ForEach(ToolbarAction.allCases) { action in
                        Button(action.rawValue, systemImage: action.symbol) { perform(action) }
                            .keyboardShortcut(KeyEquivalent(action.key))
                            .onHover { hover(action, isHovering: $0) }
                    }
                }
            }
            .background(FloatingWindowConfigurator())
    }

    private func perform(_ action: ToolbarAction) {
        hover(action, isHovering: false)
        switch action {
        case .actionPanel, .browseNotes: break
        case .createNote: store.create()
        }
    }

    /// Shows the tooltip after a short delay; once visible, it follows the pointer between buttons instantly.
    private func hover(_ action: ToolbarAction, isHovering: Bool) {
        hoverTask?.cancel()
        if isHovering, tooltip != nil {
            tooltip = action
            return
        }
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(isHovering ? 450 : 120))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.18)) { tooltip = isHovering ? action : nil }
        }
    }
}

private struct Tooltip: View {
    let action: ToolbarAction

    var body: some View {
        HStack(spacing: 8) {
            Text(action.rawValue)
                .font(.callout.weight(.medium))
            HStack(spacing: 3) {
                ForEach(["⌘", action.key.uppercased()], id: \.self) { key in
                    Text(key)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(.fill.secondary, in: .rect(cornerRadius: 5))
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
    }
}

private struct VimModePill: View {
    let mode: VimMode

    var body: some View {
        Text(mode.label)
            .font(.caption.weight(.semibold).monospaced())
            .foregroundStyle(.secondary)
            .contentTransition(.interpolate)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
            .animation(.snappy(duration: 0.2), value: mode)
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
