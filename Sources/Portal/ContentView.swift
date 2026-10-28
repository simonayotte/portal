import SwiftUI

private enum ToolbarAction: String, CaseIterable, Identifiable {
    case actionPanel = "Action Panel"
    case browseNotes = "Browse Notes"
    case createNote = "Create Note"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .actionPanel: "command"
        case .browseNotes: "square.stack"
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

private enum Palette {
    case actions, notes
}

struct ContentView: View {
    @Bindable var store: NoteStore
    @Environment(\.appearsActive) private var appearsActive
    @State private var tooltip: ToolbarAction?
    @State private var hoverTask: Task<Void, Never>?
    @State private var palette: Palette?
    @State private var editor = EditorController()
    @State private var navigation = NoteNavigation()

    var body: some View {
        Group {
            if store.vault == nil {
                NoVaultView(openVault: chooseVault)
            } else {
                editorView
            }
        }
        .frame(minWidth: 280, minHeight: 220)
        .background { SettingsActionBridge() }
        .background {
            NoteBackground().ignoresSafeArea()
        }
        .windowMinimizeBehavior(.disabled)
        .windowFullScreenBehavior(.disabled)
        .toolbar(removing: .title)
        .toolbar { toolbarContent }
        .background {
            Button("Open Daily Note") { store.openDailyNote() }
                .keyboardShortcut("d")
                .opacity(0)
                .allowsHitTesting(false)
        }
        .onAppear {
            editor.openLink = { store.open(link: $0) }
            editor.saveImage = { store.saveImage($0, fileExtension: $1) }
            editor.resolveImage = { store.resolveImage($0) }
        }
        .onChange(of: appearsActive) { _, isActive in
            guard !isActive else { return }
            hoverTask?.cancel()
            tooltip = nil
        }
        .onChange(of: store.selectedID, initial: true) { _, id in
            if let id { navigation.recordOpened(id) }
        }
    }

    private var editorView: some View {
        MarkdownEditor(text: $store.text, noteID: store.selectedID, controller: editor)
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
            .overlay(alignment: .top) {
                if let palette {
                    ZStack(alignment: .top) {
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture(perform: closePalette)
                        paletteView(palette)
                            .id(palette)
                            .containerRelativeFrame(.horizontal) { width, _ in min(width * 0.7, 320) }
                            .padding(.top, 8)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(store.selected?.title ?? "Untitled")
                .font(.headline.weight(.regular))
                .foregroundStyle(appearsActive ? .secondary : .tertiary)
                .lineLimit(1)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 2) {
                ForEach(ToolbarAction.allCases) { action in
                    Button { perform(action) } label: {
                        Image(systemName: action.symbol)
                            .font(.system(size: 16))
                    }
                    .buttonStyle(ToolbarIconButtonStyle())
                    .accessibilityLabel(action.rawValue)
                    .keyboardShortcut(KeyEquivalent(action.key))
                    .onHover { hover(action, isHovering: $0) }
                }
            }
            .opacity(appearsActive ? 1 : 0)
            .allowsHitTesting(appearsActive)
            .accessibilityHidden(!appearsActive)
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open Vault"
        panel.message = "Choose an Obsidian vault folder"
        panel.directoryURL = store.vault ?? FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.open(vault: url)
    }

    private func perform(_ action: ToolbarAction) {
        hover(action, isHovering: false)
        switch action {
        case .actionPanel: togglePalette(.actions)
        case .browseNotes: togglePalette(.notes)
        case .createNote: store.create()
        }
    }

    private func togglePalette(_ target: Palette) {
        if palette == target { return closePalette() }
        guard store.vault != nil else { return }
        if target == .notes { store.refresh() }
        withAnimation(.snappy(duration: 0.18)) { palette = target }
    }

    private func closePalette() {
        withAnimation(.snappy(duration: 0.15)) { palette = nil }
        editor.focus()
    }

    private func paletteView(_ palette: Palette) -> CommandPalette {
        switch palette {
        case .actions:
            CommandPalette(
                prompt: "Search actions...",
                items: MarkdownAction.all.map { action in
                    PaletteItem(id: action.id, title: action.title, shortcut: action.shortcut) { editor.perform(action) }
                } + pinNoteAction + [
                    PaletteItem(id: "daily-note", title: "Open Daily Note", shortcut: "⌘D") { store.openDailyNote() },
                    PaletteItem(id: "open-vault", title: "Open Vault…", perform: chooseVault),
                    PaletteItem(id: "settings", title: "Settings…", shortcut: "⌘,") { SettingsAccess.shared.show() },
                ],
                actionLabel: "Run Action",
                dismiss: closePalette
            )
        case .notes:
            CommandPalette(
                prompt: "Search notes...",
                items: navigation.ordered(store.notes).map { note in
                    PaletteItem(
                        id: NoteNavigation.identity(note.id), title: note.title, detail: store.folder(of: note),
                        isPinned: navigation.isPinned(note.id), togglePin: { navigation.togglePin(note.id) }
                    ) {
                        store.select(note.id)
                    }
                },
                actionLabel: "Open Note",
                dismiss: closePalette
            )
        }
    }

    private var pinNoteAction: [PaletteItem] {
        guard let note = store.selected else { return [] }
        return [PaletteItem(id: "toggle-note-pin", title: navigation.isPinned(note.id) ? "Unpin Current Note" : "Pin Current Note") {
            navigation.togglePin(note.id)
        }]
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

/// Plain toolbar icon with a soft rounded highlight on hover and press.
private struct ToolbarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButton(configuration: configuration)
    }

    private struct IconButton: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .background(highlight, in: .rect(cornerRadius: 7))
                .contentShape(.rect)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }

        private var highlight: AnyShapeStyle {
            if configuration.isPressed { AnyShapeStyle(.fill.secondary) }
            else if isHovered { AnyShapeStyle(.fill.tertiary) }
            else { AnyShapeStyle(.clear) }
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
                KeyCap("⌘")
                KeyCap(action.key.uppercased())
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
    }
}

private struct NoVaultView: View {
    let openVault: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No vault open")
                .font(.headline)
                .foregroundStyle(.secondary)
            Button("Open Vault…", action: openVault)
                .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
