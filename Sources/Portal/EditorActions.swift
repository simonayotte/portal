import AppKit

/// Gives SwiftUI a handle on the editor: focus it and run formatting actions on it.
@MainActor
final class EditorController {
    weak var textView: MarkdownTextView?

    func focus() {
        textView?.window?.makeFirstResponder(textView)
    }

    func perform(_ action: MarkdownAction) {
        focus()
        if let textView { action.perform(textView) }
    }
}

/// A Markdown insertion listed in the Action Panel.
struct MarkdownAction: Identifiable {
    let title: String
    var shortcut: String?
    let perform: @MainActor (MarkdownTextView) -> Void

    var id: String { title }

    @MainActor static let all: [MarkdownAction] = [
        MarkdownAction(title: "Insert: Bold", shortcut: "⌘B") { $0.toggleWrap("**") },
        MarkdownAction(title: "Insert: Italic", shortcut: "⌘I") { $0.toggleWrap("*") },
        MarkdownAction(title: "Insert: Strikethrough") { $0.toggleWrap("~~") },
        MarkdownAction(title: "Insert: Inline Code") { $0.toggleWrap("`") },
        MarkdownAction(title: "Insert: Link", shortcut: "⇧⌘K") { $0.insertLink() },
        MarkdownAction(title: "Insert: Task", shortcut: "⌘L") { $0.toggleTask() },
        MarkdownAction(title: "Insert: Heading 1") { $0.setLinePrefix("# ") },
        MarkdownAction(title: "Insert: Heading 2") { $0.setLinePrefix("## ") },
        MarkdownAction(title: "Insert: Heading 3") { $0.setLinePrefix("### ") },
        MarkdownAction(title: "Insert: Bulleted List") { $0.setLinePrefix("- ") },
        MarkdownAction(title: "Insert: Numbered List") { $0.setLinePrefix("1. ") },
        MarkdownAction(title: "Insert: Quote") { $0.setLinePrefix("> ") },
        MarkdownAction(title: "Insert: Code Block") { $0.insertCodeBlock() },
        MarkdownAction(title: "Insert: Divider") { $0.insertDivider() },
    ]
}
