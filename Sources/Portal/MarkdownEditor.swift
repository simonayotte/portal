import SwiftUI
import UniformTypeIdentifiers

/// Live-preview Markdown editor: the source is styled in place and syntax markers
/// are hidden everywhere except the line being edited.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let noteID: URL?
    let controller: EditorController

    static let inset = NSSize(width: 18, height: 14)

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownTextView.make()
        textView.delegate = context.coordinator
        controller.textView = textView

        let scrollView = PositionRestoringScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.findBarPosition = .aboveContent

        context.coordinator.attach(to: scrollView)
        context.coordinator.load(text, noteID: noteID)
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in coordinator?.focusInitially() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.load(text, noteID: noteID)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: MarkdownTextView?
        private weak var scrollView: NSScrollView?
        private let positions: NotePositionStore
        private var noteID: URL?
        private var hasLoaded = false
        private var initialFocusPending = true
        private var isRestoring = false
        private var pendingScroll: NSPoint?
        private var saveTask: Task<Void, Never>?

        init(text: Binding<String>, positions: NotePositionStore = .shared) {
            self.text = text
            self.positions = positions
        }

        func attach(to scrollView: NSScrollView) {
            self.scrollView = scrollView
            textView = scrollView.documentView as? MarkdownTextView
            textView?.delegate = self
            scrollView.contentView.postsBoundsChangedNotifications = true
            (scrollView as? PositionRestoringScrollView)?.didLayout = { [weak self] in self?.restoreScroll() }
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            center.addObserver(self, selector: #selector(flushPosition), name: NSApplication.willTerminateNotification, object: nil)
            center.addObserver(self, selector: #selector(flushPosition), name: NSApplication.didResignActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil)
        }

        func load(_ string: String, noteID: URL?) {
            guard let textView else { return }
            let changedNote = !hasLoaded || self.noteID != noteID
            guard changedNote || textView.string != string else { return }
            // Capture while the old document and its selection still belong to the old ID.
            let previous = currentPosition()
            if hasLoaded, changedNote { flushPosition() }
            if hasLoaded { initialFocusPending = false }
            saveTask?.cancel()
            isRestoring = true
            self.noteID = noteID
            hasLoaded = true
            let saved = changedNote ? noteID.flatMap { positions.position(for: $0) } : previous
            (textView.layoutManager as? MarkdownLayoutManager)?.forgetImages()
            textView.replaceNoteContents(with: string)
            textView.restyle()
            let start = MarkdownStyler.bodyStart(of: string as NSString)
            let position = (saved ?? NotePosition(
                selection: NSRange(location: start, length: 0), scrollOrigin: .zero,
                vim: .init(mode: .normal, cursor: start, anchor: start)
            )).clamped(toUTF16Length: (string as NSString).length)
            textView.vim.restore(selection: position.selection, state: position.vim)
            textView.updateActiveLine()
            textView.breakUndoCoalescing()
            textView.undoManager?.removeAllActions()
            pendingScroll = position.scrollOrigin
            isRestoring = false
            restoreScroll()
        }

        /// Only creation requests focus; note switches and reloads must never take it.
        func focusInitially() {
            guard initialFocusPending else { return }
            initialFocusPending = false
            guard let textView, let window = textView.window, window.isKeyWindow,
                  let position = currentPosition() else { return }
            isRestoring = true
            _ = window.makeFirstResponder(textView)
            // Becoming first responder may reveal the caret or otherwise change the viewport.
            textView.vim.restore(selection: position.selection, state: position.vim)
            textView.updateActiveLine()
            pendingScroll = position.scrollOrigin
            isRestoring = false
            restoreScroll()
        }

        private func currentPosition() -> NotePosition? {
            guard hasLoaded, let textView, let scrollView else { return nil }
            return NotePosition(
                selection: textView.selectedRange(),
                scrollOrigin: pendingScroll ?? scrollView.contentView.bounds.origin,
                vim: textView.vim.selectionState
            ).clamped(toUTF16Length: (textView.string as NSString).length)
        }

        private func restoreScroll() {
            guard !isRestoring, let origin = pendingScroll, let textView, let scrollView,
                  scrollView.contentSize.width > 0, scrollView.contentSize.height > 0 else { return }
            isRestoring = true
            if let container = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: container)
            }
            textView.sizeToFit()
            var bounds = scrollView.contentView.bounds
            bounds.origin = origin
            let clamped = scrollView.contentView.constrainBoundsRect(bounds)
            scrollView.contentView.scroll(to: clamped.origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            pendingScroll = nil
            isRestoring = false
        }

        private func scheduleSave() {
            guard !isRestoring, hasLoaded, noteID != nil else { return }
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.flushPosition()
            }
        }

        @objc private func boundsChanged(_ notification: Notification) {
            guard !isRestoring else { return }
            restoreScroll()
            scheduleSave()
        }

        @objc private func flushPosition() {
            saveTask?.cancel()
            saveTask = nil
            guard let noteID, let position = currentPosition() else { return }
            positions.save(position, for: noteID)
        }

        @objc private func windowWillClose(_ notification: Notification) {
            if let window = notification.object as? NSWindow, window === textView?.window { flushPosition() }
        }

        func detach() {
            flushPosition()
            NotificationCenter.default.removeObserver(self)
            (scrollView as? PositionRestoringScrollView)?.didLayout = nil
            textView?.delegate = nil
            textView = nil
            scrollView = nil
            hasLoaded = false
            initialFocusPending = false
        }

        func textDidChange(_ notification: Notification) {
            guard !isRestoring, let textView else { return }
            textView.restyle()
            text.wrappedValue = textView.string
            scheduleSave()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isRestoring else { return }
            textView?.updateActiveLine()
            scheduleSave()
        }

        /// Toggles `- [ ]` / `- [x]` when a checkbox is clicked, and follows `[[wikilinks]]`.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL, url.scheme == MarkdownStyler.wikilinkScheme,
               let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value {
                (textView as? MarkdownTextView)?.openLink?(target)
                return true
            }
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

/// TextKit 1 text view with Markdown editing behaviors: Vim keys, list continuation, list indenting and shortcuts.
final class MarkdownTextView: NSTextView {
    lazy var vim = VimEngine(view: self)
    var openLink: ((String) -> Void)?
    /// Saves pasted image data (with its file extension) to the vault and returns the embed to insert.
    var saveImage: ((Data, String) -> String?)?

    private static let listPrefix = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:([-*+])[ \t]+(\[[ xX]\][ \t]+)?|(\d+)([.)])[ \t]+|(>)[ \t]?)"#
    )
    private static let blockPrefix = try! NSRegularExpression(
        pattern: #"^([ \t]*)(#{1,6}[ \t]+|[-*+][ \t]+\[[ xX]\][ \t]+|[-*+][ \t]+|\d+[.)][ \t]+|>[ \t]?)?"#
    )

    static func make() -> MarkdownTextView {
        let textView = MarkdownTextView(usingTextLayoutManager: false)
        textView.textContainer?.replaceLayoutManager(MarkdownLayoutManager())
        textView.isRichText = false
        textView.usesFindPanel = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
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

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, closeFindBar() { return }
        if !vim.handle(event) { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        vim.didClick()
    }

    private var markdownLayoutManager: MarkdownLayoutManager? { layoutManager as? MarkdownLayoutManager }
    /// Draws Vim's block cursor on the character at `index`, or the thin caret when `nil`.
    func showBlockCursor(at index: Int?) {
        guard let layoutManager = markdownLayoutManager, layoutManager.blockCursor != index else { return }
        layoutManager.blockCursor = index
        // `nil` resets the thin caret to the system color; it is hidden behind the block cursor.
        insertionPointColor = index == nil ? nil : .clear
        updateInsertionPointStateAndRestartTimer(true)
        needsDisplay = true
    }

    func restyle() {
        guard let textStorage else { return }
        MarkdownStyler.style(textStorage)
        typingAttributes = MarkdownStyler.baseAttributes
    }

    /// Reveals syntax on the line(s) holding the selection and hides it everywhere else.
    func updateActiveLine() {
        guard let layoutManager = markdownLayoutManager else { return }
        var line = (string as NSString).paragraphRange(for: selectedRange())
        // A rendered block (a diagram) shows its source while the caret is anywhere in it.
        for index in [line.location, NSMaxRange(line) - 1] where index >= 0 && index < (textStorage?.length ?? 0) {
            if let block = textStorage?.attribute(.markdownRendered, at: index, effectiveRange: nil) as? RenderedBlock {
                line = NSUnionRange(line, (string as NSString).paragraphRange(for: block.range))
            }
        }
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

    // MARK: Pasting images

    /// Lets Paste accept a clipboard holding only an image.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff]
    }

    /// Pasting an image (a screenshot, or an image file copied in Finder) saves it to the vault and embeds it.
    override func paste(_ sender: Any?) {
        if !pasteImage(from: .general) { super.paste(sender) }
        vim.didEdit(typing: false)
    }

    /// Embeds the pasteboard's image on a line of its own (below the cursor's line in Vim Normal mode).
    /// Returns `false` when it holds no image.
    func pasteImage(from pasteboard: NSPasteboard) -> Bool {
        guard let image = Self.pastedImage(from: pasteboard), let embed = saveImage?(image.data, image.fileExtension) else { return false }
        let line = currentLine().range
        let target = vim.mode == .normal ? NSRange(location: NSMaxRange(line), length: 0) : editingSelection
        let lead = target.location > line.location ? "\n" : ""
        let trail = NSMaxRange(target) < NSMaxRange(line) ? "\n" : ""
        replace(target, with: lead + embed + trail)
        return true
    }

    private static func pastedImage(from pasteboard: NSPasteboard) -> (data: Data, fileExtension: String)? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let file = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?.first,
           let data = try? Data(contentsOf: file) {
            return (data, file.pathExtension.lowercased())
        }
        // Text wins when the clipboard has both (e.g. cells copied from a spreadsheet), unless it is just the image's URL.
        if let text = pasteboard.string(forType: .string), !text.hasPrefix("http") { return nil }
        if let png = pasteboard.data(forType: .png) { return (png, "png") }
        if let tiff = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return (png, "png")
        }
        return nil
    }

    // MARK: Formatting shortcuts

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if performFindKeyEquivalent(with: event) { return true }
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (modifiers, event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "b"): toggleWrap("**")
        case (.command, "i"): toggleWrap("*")
        case (.command, "l"): toggleTask()
        case ([.command, .shift], "k"): insertLink()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// The range formatting applies to: in Vim Normal mode that is the caret, not the block cursor.
    private var editingSelection: NSRange {
        vim.mode == .normal ? NSRange(location: selectedRange().location, length: 0) : selectedRange()
    }

    /// Turns the current line into a task, or checks / unchecks it when it already is one.
    func toggleTask() {
        let (line, prefix) = currentLine()
        let text = string as NSString
        let caret = editingSelection
        func insert(_ marker: String, at location: Int) {
            let shift = caret.location >= location ? (marker as NSString).length : 0
            replace(NSRange(location: location, length: 0), with: marker, select: NSRange(location: caret.location + shift, length: caret.length))
        }

        if let box = prefix?.range(at: 3), box.location != NSNotFound {
            let mark = NSRange(location: box.location + 1, length: 1)
            replace(mark, with: text.substring(with: mark) == " " ? "x" : " ", select: caret)
        } else if let prefix, prefix.range(at: 2).location != NSNotFound {
            insert("[ ] ", at: NSMaxRange(prefix.range))
        } else {
            let indent = text.substring(with: line).prefix { $0 == " " || $0 == "\t" }.utf16.count
            insert("- [ ] ", at: line.location + indent)
        }
        vim.didEdit(typing: false)
    }

    /// Gives the current line a block prefix (`# `, `- `, `> ` …) in place of any other, or removes it if it already has it.
    func setLinePrefix(_ prefix: String) {
        let (line, _) = currentLine()
        let caret = editingSelection
        guard let match = Self.blockPrefix.firstMatch(in: string, range: line) else { return }
        let existing = match.range(at: 2)
        let target = existing.location == NSNotFound ? NSRange(location: NSMaxRange(match.range(at: 1)), length: 0) : existing
        let replacement = (string as NSString).substring(with: target) == prefix ? "" : prefix
        let length = (replacement as NSString).length
        let location = if caret.location < target.location {
            caret.location
        } else if caret.location >= NSMaxRange(target) {
            caret.location + length - target.length
        } else {
            target.location + length
        }
        replace(target, with: replacement, select: NSRange(location: location, length: 0))
        vim.didEdit(typing: false)
    }

    /// Wraps the selection as link text and puts the caret in the URL, or inserts an empty link.
    func insertLink() {
        let selection = editingSelection
        let selected = (string as NSString).substring(with: selection)
        let caret = selected.isEmpty ? selection.location + 1 : NSMaxRange(selection) + 3
        replace(selection, with: "[\(selected)]()", select: NSRange(location: caret, length: 0))
        vim.didEdit(typing: true)
    }

    /// Fences the selection as a code block, starting it on its own line.
    func insertCodeBlock() {
        let selection = editingSelection
        let selected = (string as NSString).substring(with: selection)
        let lead = selection.location > currentLine().range.location ? "\n" : ""
        let start = selection.location + (lead as NSString).length + 4
        replace(selection, with: lead + "```\n" + selected + "\n```", select: NSRange(location: start, length: (selected as NSString).length))
        vim.didEdit(typing: selected.isEmpty)
    }

    /// Adds a `---` divider below the current line.
    func insertDivider() {
        let line = currentLine().range
        if line.length == 0 {
            replace(line, with: "---\n")
        } else {
            replace(NSRange(location: NSMaxRange(line), length: 0), with: "\n---\n")
        }
        vim.didEdit(typing: false)
    }

    /// Wraps the selection in `marker`, or unwraps it when it is already wrapped.
    func toggleWrap(_ marker: String) {
        let text = string as NSString
        let selection = editingSelection
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
            vim.didEdit(typing: false)
        } else {
            replace(selection, with: marker + selected + marker, select: NSRange(location: selection.location + length, length: selection.length))
            vim.didEdit(typing: selection.length == 0)
        }
    }
}
