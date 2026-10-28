import AppKit

/// Gives SwiftUI a handle on the editor: focus it and run formatting actions on it.
@MainActor
final class EditorController {
    weak var textView: MarkdownTextView? {
        didSet {
            textView?.openLink = { [weak self] in self?.openLink?($0) }
            textView?.saveImage = { [weak self] in self?.saveImage?($0, $1) ?? nil }
            layoutManager?.resolveImage = resolveImage
        }
    }
    /// Opens the note a clicked `[[wikilink]]` points to.
    var openLink: ((String) -> Void)?
    /// Saves a pasted image to the vault and returns the embed to insert.
    var saveImage: ((Data, String) -> String?)?
    /// Finds the file an image embed points to.
    var resolveImage: ((ImageEmbed) -> URL?)? {
        didSet { layoutManager?.resolveImage = resolveImage }
    }

    private var layoutManager: MarkdownLayoutManager? { textView?.layoutManager as? MarkdownLayoutManager }

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
