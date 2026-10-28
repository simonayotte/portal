import SwiftUI

struct PaletteItem: Identifiable {
    let id: String
    let title: String
    /// Keyboard shortcut shown as key caps, e.g. `⇧⌘K`.
    var shortcut: String?
    /// Trailing secondary text.
    var detail: String?
    let perform: () -> Void
}

/// Searchable list: type to filter, ↑ ↓ (or ⌃N ⌃P) to move, ↩ to run, Esc to close.
struct CommandPalette: View {
    let prompt: String
    let items: [PaletteItem]
    let actionLabel: String
    let dismiss: () -> Void

    @State private var query = ""
    @State private var selection: PaletteItem.ID?

    static let rowHeight: CGFloat = 30
    private static let rowSpacing: CGFloat = 2
    private static let maxVisibleRows = 10

    private var results: [PaletteItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            list
            Divider()
            footer
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .onAppear { selection = results.first?.id }
        .onChange(of: query) { selection = results.first?.id }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            PaletteSearchField(prompt: prompt, text: $query, onMove: move, onSubmit: runSelection, onCancel: dismiss)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(.fill.tertiary, in: .rect(cornerRadius: 10))
        .padding(8)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(results) { item in
                        PaletteRow(item: item, isSelected: item.id == selection)
                            .id(item.id)
                            .onTapGesture { run(item) }
                            .onHover { if $0 { selection = item.id } }
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: CGFloat(min(max(results.count, 1), Self.maxVisibleRows)) * (Self.rowHeight + Self.rowSpacing) + 6)
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .overlay {
            if results.isEmpty {
                Text("No Results")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Spacer()
            Text(actionLabel)
                .foregroundStyle(.secondary)
            KeyCap("↩")
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func move(_ offset: Int) {
        let ids = results.map(\.id)
        guard !ids.isEmpty else { return }
        let current = selection.flatMap { ids.firstIndex(of: $0) } ?? 0
        selection = ids[min(max(current + offset, 0), ids.count - 1)]
    }

    private func runSelection() {
        if let item = results.first(where: { $0.id == selection }) ?? results.first { run(item) }
    }

    private func run(_ item: PaletteItem) {
        dismiss()
        item.perform()
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack {
            Text(item.title)
                .lineLimit(1)
            Spacer(minLength: 12)
            if let shortcut = item.shortcut {
                HStack(spacing: 3) {
                    ForEach(Array(shortcut.enumerated()), id: \.offset) { _, key in
                        KeyCap(String(key), onAccent: isSelected)
                    }
                }
            }
            if let detail = item.detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .frame(height: CommandPalette.rowHeight)
        .background {
            if isSelected { RoundedRectangle(cornerRadius: 8).fill(Color.accentColor) }
        }
        .contentShape(.rect)
    }
}

struct KeyCap: View {
    let key: String
    /// Drawn on the accent-colored selected row.
    var onAccent = false

    init(_ key: String, onAccent: Bool = false) {
        self.key = key
        self.onAccent = onAccent
    }

    var body: some View {
        Text(key)
            .font(.caption.weight(.semibold))
            .foregroundStyle(onAccent ? Color.white : Color.secondary)
            .frame(minWidth: 18, minHeight: 18)
            .background(onAccent ? AnyShapeStyle(Color.white.opacity(0.2)) : AnyShapeStyle(.fill.secondary), in: .rect(cornerRadius: 5))
    }
}

/// AppKit text field so ↑ ↓ (and ⌃P ⌃N), ↩ and Esc reach the palette instead of moving the field's caret.
private struct PaletteSearchField: NSViewRepresentable {
    let prompt: String
    @Binding var text: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = prompt
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField

        init(_ parent: PaletteSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}
