import AppKit

extension MarkdownTextView {
    /// Use the text view's own finder, scoped to this note and hosted by its scroll view.
    func find(_ action: NSTextFinder.Action) {
        let searchControl = focusedFindBarView
        let searchSelection = (window?.firstResponder as? NSTextView)?.selectedRange()
        // NSTextView otherwise forwards to the shared field editor when search has focus.
        window?.makeFirstResponder(self)
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        performTextFinderAction(sender)
        if action == .nextMatch || action == .previousMatch, let searchControl {
            if window?.makeFirstResponder(searchControl) == true, let searchSelection,
               let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor {
                editor.setSelectedRange(searchSelection)
            }
        }
    }

    /// Model-driven note loads must notify the native finder just like ordinary edits.
    func replaceNoteContents(with text: String) {
        let range = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: range, replacementString: text) else { return }
        string = text
        didChangeText()
    }

    @discardableResult
    func closeFindBar() -> Bool {
        guard enclosingScrollView?.isFindBarVisible == true else { return false }
        find(.hideFindInterface)
        return true
    }

    /// The panel has no SwiftUI Window scene to install Find menu commands for us.
    func performFindKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self || focusedFindBarView != nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        switch (modifiers, event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "f"): find(.showFindInterface)
        case (.command, "g"): find(.nextMatch)
        case ([.command, .shift], "g"): find(.previousMatch)
        default: return false
        }
        return true
    }

    private var focusedFindBarView: NSView? {
        guard let responder = window?.firstResponder else { return nil }
        guard let scrollView = enclosingScrollView, scrollView.isFindBarVisible,
              let bar = scrollView.findBarView else { return nil }
        // Native search fields use the window's shared field editor.
        if let editor = responder as? NSTextView, editor.isFieldEditor,
           let field = editor.delegate as? NSView, field.isDescendant(of: bar) { return field }
        if let view = responder as? NSView, view.isDescendant(of: bar) { return view }
        return nil
    }
}
