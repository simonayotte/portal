import SwiftUI

/// Live-preview Markdown editor: the source is styled in place and syntax markers
/// are hidden everywhere except the line being edited.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String

    static let inset = NSSize(width: 18, height: 14)

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, so the layout manager can hide marker glyphs.
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.layoutManager?.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.writingToolsBehavior = .none
        textView.inlinePredictionType = .no
        textView.textContainerInset = Self.inset
        textView.typingAttributes = MarkdownStyler.baseAttributes
        textView.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand]
        textView.isVerticallyResizable = true
        textView.autoresizingMask = .width
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

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
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSLayoutManagerDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        private var activeLine = NSRange()

        init(text: Binding<String>) { self.text = text }

        func load(_ string: String) {
            guard let textView, let storage = textView.textStorage else { return }
            textView.string = string
            MarkdownStyler.style(storage)
            textView.undoManager?.removeAllActions()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, let storage = textView.textStorage else { return }
            MarkdownStyler.style(storage)
            textView.typingAttributes = MarkdownStyler.baseAttributes
            text.wrappedValue = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let line = (textView.string as NSString).paragraphRange(for: textView.selectedRange())
            guard line != activeLine else { return }
            let dirty = NSUnionRange(line, activeLine)
            activeLine = line
            let range = NSIntersectionRange(dirty, NSRange(location: 0, length: textView.string.utf16.count))
            layoutManager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }

        /// Toggles `- [ ]` / `- [x]` when a checkbox is clicked.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == "task",
                  let location = Int(url.absoluteString.dropFirst("task:".count)) else { return false }
            let range = NSRange(location: location + 1, length: 1)
            let mark = (textView.string as NSString).substring(with: range) == " " ? "x" : " "
            if textView.shouldChangeText(in: range, replacementString: mark) {
                textView.textStorage?.replaceCharacters(in: range, with: mark)
                textView.didChangeText()
            }
            return true
        }

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
            properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
            characterIndexes: UnsafePointer<Int>,
            font: NSFont,
            forGlyphRange glyphRange: NSRange
        ) -> Int {
            guard let storage = layoutManager.textStorage else { return 0 }
            var newProperties = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
            var changed = false
            for i in newProperties.indices {
                let index = characterIndexes[i]
                if !NSLocationInRange(index, activeLine),
                   storage.attribute(.markdownMarker, at: index, effectiveRange: nil) != nil {
                    newProperties[i] = .null
                    changed = true
                }
            }
            guard changed else { return 0 }
            newProperties.withUnsafeBufferPointer {
                layoutManager.setGlyphs(glyphs, properties: $0.baseAddress!, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
            }
            return glyphRange.length
        }
    }
}
