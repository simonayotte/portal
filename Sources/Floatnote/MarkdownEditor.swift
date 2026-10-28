import SwiftUI

/// Live-preview Markdown editor: the source is styled in place and syntax markers
/// are hidden everywhere except the line being edited.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String

    static let inset = NSSize(width: 18, height: 14)

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownTextView.make()
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        context.coordinator.textView = textView
        context.coordinator.load(text)
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if context.coordinator.textView?.string != text {
            context.coordinator.load(text)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: MarkdownTextView?

        init(text: Binding<String>) { self.text = text }

        func load(_ string: String) {
            guard let textView else { return }
            textView.string = string
            textView.restyle()
            textView.updateActiveLine()
            textView.undoManager?.removeAllActions()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            textView.restyle()
            text.wrappedValue = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            textView?.updateActiveLine()
        }

        /// Toggles `- [ ]` / `- [x]` when a checkbox is clicked.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == "task",
                  let location = Int(url.absoluteString.dropFirst("task:".count)),
                  let textView = textView as? MarkdownTextView else { return false }
            let range = NSRange(location: location + 1, length: 1)
            let mark = (textView.string as NSString).substring(with: range) == " " ? "x" : " "
            textView.replace(range, with: mark)
            return true
        }
    }
}

/// TextKit 1 text view with Markdown editing behaviors: list continuation, list indenting and ⌘B / ⌘I.
final class MarkdownTextView: NSTextView {
    private static let listPrefix = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:([-*+])[ \t]+(\[[ xX]\][ \t]+)?|(\d+)([.)])[ \t]+|(>)[ \t]?)"#
    )

    static func make() -> MarkdownTextView {
        let textView = MarkdownTextView(usingTextLayoutManager: false)
        textView.textContainer?.replaceLayoutManager(MarkdownLayoutManager())
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.writingToolsBehavior = .none
        textView.inlinePredictionType = .no
        textView.textContainerInset = MarkdownEditor.inset
        textView.typingAttributes = MarkdownStyler.baseAttributes
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.isVerticallyResizable = true
        textView.autoresizingMask = .width
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        return textView
    }

    private var markdownLayoutManager: MarkdownLayoutManager? { layoutManager as? MarkdownLayoutManager }

    func restyle() {
        guard let textStorage else { return }
        MarkdownStyler.style(textStorage)
        typingAttributes = MarkdownStyler.baseAttributes
    }

    /// Reveals syntax on the line(s) holding the selection and hides it everywhere else.
    func updateActiveLine() {
        guard let layoutManager = markdownLayoutManager else { return }
        let line = (string as NSString).paragraphRange(for: selectedRange())
        let previous = layoutManager.activeLine
        guard line != previous else { return }
        layoutManager.activeLine = line
        let dirty = NSIntersectionRange(NSUnionRange(line, previous), NSRange(location: 0, length: (string as NSString).length))
        layoutManager.invalidateGlyphs(forCharacterRange: dirty, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: dirty, actualCharacterRange: nil)
    }

    /// Undoable replacement that goes through the normal change notifications.
    func replace(_ range: NSRange, with replacement: String, select selection: NSRange? = nil) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(selection ?? NSRange(location: range.location + (replacement as NSString).length, length: 0))
    }

    // MARK: Lists

    private func currentLine() -> (range: NSRange, prefix: NSTextCheckingResult?) {
        let text = string as NSString
        var end = 0
        text.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: selectedRange().location, length: 0))
        let start = text.lineRange(for: NSRange(location: selectedRange().location, length: 0)).location
        let range = NSRange(location: start, length: end - start)
        return (range, Self.listPrefix.firstMatch(in: string, range: range))
    }

    override func insertNewline(_ sender: Any?) {
        let caret = selectedRange()
        let (line, prefix) = currentLine()
        guard caret.length == 0, let prefix, caret.location >= NSMaxRange(prefix.range) else {
            return super.insertNewline(sender)
        }
        let text = string as NSString
        func group(_ index: Int) -> String? {
            let range = prefix.range(at: index)
            return range.location == NSNotFound ? nil : text.substring(with: range)
        }

        // Enter on an empty item ends the list.
        if prefix.range.length == line.length {
            replace(prefix.range, with: "")
            return
        }
        let marker = if let bullet = group(2) {
            "\(bullet) " + (group(3) != nil ? "[ ] " : "")
        } else if let number = group(4).flatMap({ Int($0) }), let delimiter = group(5) {
            "\(number + 1)\(delimiter) "
        } else {
            "> "
        }
        replace(caret, with: "\n" + (group(1) ?? "") + marker)
    }

    override func insertTab(_ sender: Any?) {
        let (line, prefix) = currentLine()
        guard let prefix, prefix.range(at: 6).location == NSNotFound else { return super.insertTab(sender) }
        let caret = selectedRange()
        replace(NSRange(location: line.location, length: 0), with: "\t", select: NSRange(location: caret.location + 1, length: caret.length))
    }

    override func insertBacktab(_ sender: Any?) {
        let (line, prefix) = currentLine()
        guard let prefix, prefix.range(at: 6).location == NSNotFound else { return super.insertBacktab(sender) }
        let indent = (string as NSString).substring(with: prefix.range(at: 1))
        let removed = indent.hasPrefix("\t") ? 1 : min(indent.prefix { $0 == " " }.count, 4)
        guard removed > 0 else { return }
        let caret = selectedRange()
        replace(
            NSRange(location: line.location, length: removed),
            with: "",
            select: NSRange(location: max(line.location, caret.location - removed), length: caret.length)
        )
    }

    // MARK: Formatting shortcuts

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "b": toggleWrap("**")
        case "i": toggleWrap("*")
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// Wraps the selection in `marker`, or unwraps it when it is already wrapped.
    func toggleWrap(_ marker: String) {
        let text = string as NSString
        let selection = selectedRange()
        let length = (marker as NSString).length
        let before = NSRange(location: selection.location - length, length: length)
        let after = NSRange(location: NSMaxRange(selection), length: length)
        let selected = text.substring(with: selection)

        if before.location >= 0, NSMaxRange(after) <= text.length,
           text.substring(with: before) == marker, text.substring(with: after) == marker {
            replace(
                NSRange(location: before.location, length: selection.length + length * 2),
                with: selected,
                select: NSRange(location: before.location, length: selection.length)
            )
        } else {
            replace(selection, with: marker + selected + marker, select: NSRange(location: selection.location + length, length: selection.length))
        }
    }
}
