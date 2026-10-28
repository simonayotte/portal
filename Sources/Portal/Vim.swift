import AppKit

enum VimMode {
    case normal, insert, visual, visualLine

    var isVisual: Bool { self == .visual || self == .visualLine }
}

/// Vim keybindings for `MarkdownTextView`: modes, counts, motions, operators and visual selection.
/// Normal and Visual mode show a block cursor; Insert mode shows the thin caret.
@MainActor
final class VimEngine {
    private(set) var mode = VimMode.normal

    private unowned let view: MarkdownTextView
    private var keys: [String] = []
    private var cursor = 0
    private var anchor = 0
    /// Column that `j` / `k` try to keep.
    private var column: Int?
    private var register = (text: "", linewise: false)

    init(view: MarkdownTextView) { self.view = view }

    private var buffer: Buffer { Buffer(view.string as NSString) }

    // MARK: Input

    /// Returns `true` when the key was consumed by Vim.
    func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.contains(.command) else { return false }
        let characters = event.charactersIgnoringModifiers ?? ""
        let isEscape = event.keyCode == 53 || (modifiers == .control && characters == "[")

        if mode == .insert {
            guard isEscape, !view.hasMarkedText() else { return false }
            feed("<Esc>")
            return true
        }
        let key: String? = switch (event.keyCode, modifiers) {
        case _ where isEscape: "<Esc>"
        case (_, .control) where ["r", "d", "u"].contains(characters): "<C-\(characters)>"
        case (123, _), (51, _): "h"
        case (124, _): "l"
        case (125, _), (36, _): "j"
        case (126, _): "k"
        case (_, let flags) where !flags.contains(.control): event.characters.flatMap { $0.count == 1 ? $0 : nil }
        default: nil
        }
        if let key { feed(key) }
        return true
    }

    func feed(_ key: String) {
        if mode == .insert {
            if key == "<Esc>" { leaveInsert() }
            return
        }
        if key == "<Esc>" {
            keys = []
            if mode.isVisual { mode = .normal }
        } else {
            keys.append(key)
            if run(keys) { keys = [] }
        }
        sync()
    }

    /// Back to Normal mode at the start of a freshly loaded note.
    func reset() {
        keys = []
        cursor = MarkdownStyler.bodyStart(of: view.string as NSString)
        mode = .normal
        sync()
    }

    /// A mouse click moves the cursor; a drag selection starts Visual mode.
    func didClick() {
        guard mode != .insert else { return }
        let selection = view.selectedRange()
        column = nil
        if selection.length > 1 {
            anchor = selection.location
            cursor = NSMaxRange(selection) - 1
            mode = .visual
        } else {
            cursor = selection.location
            if mode.isVisual { mode = .normal }
        }
        sync()
    }

    /// Picks the mode after a formatting edit made outside Vim's own keys (⌘B, Action Panel …):
    /// a selection stays selected, and an empty placeholder like `****` is ready for typing.
    func didEdit(typing: Bool) {
        guard mode != .insert else { return }
        let selection = view.selectedRange()
        if selection.length > 0 {
            anchor = selection.location
            cursor = NSMaxRange(selection) - 1
            mode = .visual
        } else {
            cursor = selection.location
            mode = typing ? .insert : .normal
        }
        sync()
    }

    private func leaveInsert() {
        view.breakUndoCoalescing()
        let buffer = buffer
        let caret = view.selectedRange().location
        cursor = max(buffer.start(buffer.line(of: caret)), caret - 1)
        mode = .normal
        sync()
    }

    /// Shows the cursor or selection for the current mode.
    private func sync() {
        let buffer = buffer
        switch mode {
        case .insert:
            view.setSelectedRange(NSRange(location: min(cursor, buffer.length), length: 0))
        case .normal:
            cursor = buffer.clamp(cursor)
            view.setSelectedRange(NSRange(location: cursor, length: 0))
        case .visual:
            cursor = buffer.clamp(cursor)
            let low = min(anchor, cursor)
            view.setSelectedRange(NSRange(location: low, length: min(max(anchor, cursor) + 1, buffer.length) - low))
        case .visualLine:
            cursor = buffer.clamp(cursor)
            let start = buffer.start(buffer.line(of: min(anchor, cursor)))
            view.setSelectedRange(NSRange(location: start, length: buffer.end(buffer.line(of: max(anchor, cursor))) - start))
        }
        view.showBlockCursor(at: mode == .insert ? nil : cursor)
        view.scrollRangeToVisible(NSRange(location: cursor, length: 0))
    }

    // MARK: Commands

    /// Runs the pending keys. Returns `false` while more keys are needed.
    private func run(_ keys: [String]) -> Bool {
        var index = 0
        func readCount() -> Int? {
            var digits = ""
            while index < keys.count, let digit = keys[index].first, keys[index].count == 1,
                  digit.isASCII, digit.isNumber, !(digits.isEmpty && digit == "0") {
                digits.append(digit)
                index += 1
            }
            return Int(digits)
        }

        let count = readCount()
        guard index < keys.count else { return false }
        let key = keys[index]

        if mode == .normal, ["d", "c", "y"].contains(key) {
            index += 1
            let motionCount = readCount()
            guard index < keys.count else { return false }
            let total = count == nil && motionCount == nil ? nil : (count ?? 1) * (motionCount ?? 1)
            if keys[index] == key {
                apply(key, to: lines(total ?? 1))
                return true
            }
            switch motion(keys, at: index, count: total, operator: key) {
            case .incomplete: return false
            case .notMotion: return true
            case .motion(let motion):
                if let motion { apply(key, to: motion) }
                return true
            }
        }

        if mode.isVisual, visualCommand(key) { return true }

        switch motion(keys, at: index, count: count, operator: nil) {
        case .incomplete: return false
        case .motion(let motion):
            if let motion { cursor = motion.target }
            return true
        case .notMotion:
            command(key, count: count ?? 1)
            return true
        }
    }

    private func visualCommand(_ key: String) -> Bool {
        let selection = Motion(target: cursor, kind: mode == .visualLine ? .linewise : .inclusive)
        switch key {
        case "d", "x": apply("d", from: anchor, to: selection)
        case "c": apply("c", from: anchor, to: selection)
        case "y": apply("y", from: anchor, to: selection)
        case "o": swap(&anchor, &cursor)
        case "v": mode = mode == .visual ? .normal : .visual
        case "V": mode = mode == .visualLine ? .normal : .visualLine
        default: return false
        }
        return true
    }

    private func command(_ key: String, count: Int) {
        let buffer = buffer
        let line = buffer.line(of: cursor)
        column = nil
        switch key {
        case "i":
            mode = .insert
        case "a":
            if cursor < buffer.contentEnd(line) { cursor += 1 }
            mode = .insert
        case "I":
            cursor = buffer.firstNonBlank(line, allowEnd: true)
            mode = .insert
        case "A":
            cursor = buffer.contentEnd(line)
            mode = .insert
        case "o":
            view.setSelectedRange(NSRange(location: buffer.contentEnd(line), length: 0))
            view.insertNewline(nil)
            cursor = view.selectedRange().location
            mode = .insert
        case "O":
            let indent = buffer.firstNonBlank(line, allowEnd: true) - buffer.start(line)
            let whitespace = buffer.text.substring(with: NSRange(location: buffer.start(line), length: indent))
            view.replace(NSRange(location: buffer.start(line), length: 0), with: whitespace + "\n")
            cursor = buffer.start(line) + indent
            mode = .insert
        case "x", "s":
            let end = min(cursor + count, buffer.contentEnd(line))
            if end > cursor || key == "s" { apply(key == "s" ? "c" : "d", to: Motion(target: end, kind: .exclusive)) }
        case "X":
            let start = max(buffer.start(line), cursor - count)
            if start < cursor { apply("d", to: Motion(target: start, kind: .exclusive)) }
        case "D", "C":
            let last = min(line + count - 1, buffer.lastLine)
            apply(key == "D" ? "d" : "c", to: Motion(target: buffer.contentEnd(last), kind: .exclusive))
        case "S":
            apply("c", to: lines(count))
        case "Y":
            apply("y", to: lines(count))
        case "p", "P":
            put(after: key == "p", count: count)
        case "u", "<C-r>":
            for _ in 0..<count {
                if key == "u" { view.undoManager?.undo() } else { view.undoManager?.redo() }
            }
            cursor = view.selectedRange().location
        case "v", "V":
            anchor = cursor
            mode = key == "v" ? .visual : .visualLine
        default:
            break
        }
    }

    // MARK: Operators

    private func lines(_ count: Int) -> Motion {
        let buffer = buffer
        let last = min(buffer.line(of: cursor) + count - 1, buffer.lastLine)
        return Motion(target: buffer.start(last), kind: .linewise)
    }

    /// Applies `d`, `c` or `y` to the text between `origin` (default: the cursor) and the motion's target.
    private func apply(_ op: String, from origin: Int? = nil, to motion: Motion) {
        let buffer = buffer
        let from = origin ?? cursor
        let low = min(from, motion.target)
        let high = max(from, motion.target)
        let linewise = motion.kind == .linewise
        var range = switch motion.kind {
        case .exclusive:
            NSRange(location: low, length: high - low)
        case .inclusive:
            NSRange(location: low, length: min(high + 1, buffer.length) - low)
        case .linewise:
            NSRange(location: buffer.start(buffer.line(of: low)), length: buffer.end(buffer.line(of: high)) - buffer.start(buffer.line(of: low)))
        }
        let text = buffer.text.substring(with: range)
        register = (linewise && !text.hasSuffix("\n") ? text + "\n" : text, linewise)

        switch op {
        case "y":
            cursor = linewise ? min(from, max(motion.target, buffer.start(buffer.line(of: low)))) : low
            mode = .normal
        case "d":
            // Deleting the last line also removes the newline before it.
            if linewise, NSMaxRange(range) == buffer.length, !text.hasSuffix("\n"), range.location > 0 {
                range = NSRange(location: range.location - 1, length: range.length + 1)
            }
            view.replace(range, with: "")
            let after = self.buffer
            cursor = linewise ? after.firstNonBlank(after.line(of: min(range.location, after.length))) : range.location
            mode = .normal
        default: // "c"
            if linewise, text.hasSuffix("\n") { range.length -= 1 }
            view.replace(range, with: "")
            cursor = range.location
            mode = .insert
        }
    }

    private func put(after: Bool, count: Int) {
        let buffer = buffer
        let line = buffer.line(of: cursor)
        let text = String(repeating: register.text, count: count)
        guard !text.isEmpty else { return }

        if register.linewise {
            if !after {
                view.replace(NSRange(location: buffer.start(line), length: 0), with: text)
                cursor = self.buffer.firstNonBlank(line)
            } else if line < buffer.lastLine {
                view.replace(NSRange(location: buffer.start(line + 1), length: 0), with: text)
                cursor = self.buffer.firstNonBlank(line + 1)
            } else {
                view.replace(NSRange(location: buffer.length, length: 0), with: "\n" + text.dropLast())
                cursor = self.buffer.firstNonBlank(line + 1)
            }
        } else {
            let location = after && buffer.contentEnd(line) > buffer.start(line) ? cursor + 1 : cursor
            view.replace(NSRange(location: location, length: 0), with: text)
            cursor = location + (text as NSString).length - 1
        }
    }

    // MARK: Motions

    private struct Motion {
        enum Kind { case exclusive, inclusive, linewise }
        var target: Int
        var kind: Kind
    }

    private enum MotionResult {
        case incomplete
        case notMotion
        /// `nil` when the motion fails, e.g. `f` without a match.
        case motion(Motion?)
    }

    private func motion(_ keys: [String], at index: Int, count: Int?, operator op: String?) -> MotionResult {
        let buffer = buffer
        let n = count ?? 1
        let line = buffer.line(of: cursor)
        let key = keys[index]
        let keepsColumn = ["j", "k", "$"].contains(key)
        defer { if !keepsColumn { column = nil } }

        func repeated(_ step: (Int) -> Int, from start: Int) -> Int {
            (0..<n).reduce(start) { position, _ in step(position) }
        }
        func vertical(_ delta: Int) -> Motion {
            let target = min(max(line + delta, 0), buffer.lastLine)
            let wanted = column ?? (cursor - buffer.start(line))
            column = wanted
            let width = buffer.contentEnd(target) - buffer.start(target)
            return Motion(target: min(buffer.start(target) + min(wanted, width), buffer.lastChar(target)), kind: .linewise)
        }
        func lineNumber() -> Int { min(max((count ?? 1) - 1, 0), buffer.lastLine) }

        switch key {
        case "h":
            return .motion(Motion(target: max(buffer.start(line), cursor - n), kind: .exclusive))
        case "l":
            let end = op == nil ? buffer.lastChar(line) : buffer.contentEnd(line)
            return .motion(Motion(target: max(cursor, min(cursor + n, end)), kind: .exclusive))
        case "j":
            return .motion(vertical(n))
        case "k":
            return .motion(vertical(-n))
        case "w", "W":
            let big = key == "W"
            if op == "c", buffer.kind(cursor, big: big) != 0 {
                // `cw` on a word behaves like `ce`.
                return .motion(Motion(target: repeated({ buffer.wordEnd($0, big: big) }, from: cursor - 1), kind: .inclusive))
            }
            var target = repeated({ buffer.nextWordStart($0, big: big) }, from: cursor)
            if op != nil, target > buffer.contentEnd(line) { target = max(cursor, buffer.contentEnd(line)) }
            return .motion(Motion(target: target, kind: .exclusive))
        case "b", "B":
            return .motion(Motion(target: repeated({ buffer.previousWordStart($0, big: key == "B") }, from: cursor), kind: .exclusive))
        case "e", "E":
            return .motion(Motion(target: repeated({ buffer.wordEnd($0, big: key == "E") }, from: cursor), kind: .inclusive))
        case "0":
            return .motion(Motion(target: buffer.start(line), kind: .exclusive))
        case "^":
            return .motion(Motion(target: buffer.firstNonBlank(line), kind: .exclusive))
        case "$":
            column = .max
            let last = min(line + n - 1, buffer.lastLine)
            return .motion(op == nil
                ? Motion(target: buffer.lastChar(last), kind: .inclusive)
                : Motion(target: buffer.contentEnd(last), kind: .exclusive))
        case "<C-d>", "<C-u>":
            return .motion(Motion(target: scrollHalfPage(down: key == "<C-d>"), kind: .linewise))
        case "G":
            let target = count == nil ? buffer.lastLine : lineNumber()
            return .motion(Motion(target: buffer.firstNonBlank(target), kind: .linewise))
        case "g":
            guard index + 1 < keys.count else { return .incomplete }
            guard keys[index + 1] == "g" else { return .motion(nil) }
            return .motion(Motion(target: buffer.firstNonBlank(lineNumber()), kind: .linewise))
        case "f", "t", "F", "T":
            guard index + 1 < keys.count else { return .incomplete }
            guard let character = keys[index + 1].utf16.first else { return .motion(nil) }
            let forward = key == "f" || key == "t"
            var position = cursor
            for _ in 0..<n {
                var next = position + (forward ? 1 : -1)
                while next >= buffer.start(line), next < buffer.contentEnd(line), buffer.char(next) != character {
                    next += forward ? 1 : -1
                }
                guard next >= buffer.start(line), next < buffer.contentEnd(line) else { return .motion(nil) }
                position = next
            }
            let found = switch key {
            case "f": Motion(target: position, kind: .inclusive)
            case "t": Motion(target: max(cursor, position - 1), kind: .inclusive)
            case "F": Motion(target: position, kind: .exclusive)
            default: Motion(target: min(cursor, position + 1), kind: .exclusive)
            }
            return .motion(found)
        default:
            return .notMotion
        }
    }

    /// `<C-d>` / `<C-u>`: scrolls half a screen and returns the line start as far below / above the cursor.
    private func scrollHalfPage(down: Bool) -> Int {
        guard let layoutManager = view.layoutManager, let container = view.textContainer,
              let scrollView = view.enclosingScrollView else { return cursor }
        let clip = scrollView.contentView
        let delta = clip.bounds.height / 2 * (down ? 1 : -1)
        let line = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: cursor), effectiveRange: nil)
        let index = layoutManager.characterIndex(for: NSPoint(x: line.minX, y: line.midY + delta), in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        let top = min(max(clip.bounds.minY + delta, 0), max(view.frame.height - clip.bounds.height, 0))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top))
        scrollView.reflectScrolledClipView(clip)
        let buffer = buffer
        return buffer.firstNonBlank(buffer.line(of: index))
    }
}

/// Line and word lookups over the editor's text (UTF-16 offsets, like `NSRange`).
private struct Buffer {
    static let newline: unichar = 10

    let text: NSString
    /// Offset where each line starts.
    let starts: [Int]

    init(_ text: NSString) {
        self.text = text
        var starts = [0]
        for index in 0..<text.length where text.character(at: index) == Self.newline {
            starts.append(index + 1)
        }
        self.starts = starts
    }

    var length: Int { text.length }
    var lastLine: Int { starts.count - 1 }

    func char(_ index: Int) -> unichar { text.character(at: index) }

    func line(of position: Int) -> Int {
        var low = 0, high = lastLine
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= position { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func start(_ line: Int) -> Int { starts[line] }
    /// End of the line's text, before the newline.
    func contentEnd(_ line: Int) -> Int { line < lastLine ? starts[line + 1] - 1 : length }
    /// End of the line including its newline.
    func end(_ line: Int) -> Int { line < lastLine ? starts[line + 1] : length }
    /// Last position the Normal-mode cursor may occupy on the line.
    func lastChar(_ line: Int) -> Int { max(start(line), contentEnd(line) - 1) }

    func firstNonBlank(_ line: Int, allowEnd: Bool = false) -> Int {
        var index = start(line)
        while index < contentEnd(line), kind(index, big: true) == 0 { index += 1 }
        return allowEnd ? index : min(index, lastChar(line))
    }

    func clamp(_ position: Int) -> Int {
        let line = line(of: min(max(position, 0), length))
        return min(max(position, start(line)), lastChar(line))
    }

    /// 0 for whitespace, 1 for word characters, 2 for punctuation (a WORD is any non-blank run).
    func kind(_ index: Int, big: Bool) -> Int {
        guard index >= 0, index < length else { return 0 }
        let character = char(index)
        if character == 32 || character == 9 || character == Self.newline { return 0 }
        if big { return 1 }
        guard let scalar = Unicode.Scalar(character) else { return 1 }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil || character == 95 ? 1 : 2
    }

    func nextWordStart(_ position: Int, big: Bool) -> Int {
        var index = position
        let current = kind(index, big: big)
        if current != 0 {
            while index < length, kind(index, big: big) == current { index += 1 }
        }
        while index < length, kind(index, big: big) == 0 {
            // An empty line counts as a word.
            if char(index) == Self.newline, index + 1 < length, char(index + 1) == Self.newline { return index + 1 }
            index += 1
        }
        return index
    }

    func wordEnd(_ position: Int, big: Bool) -> Int {
        var index = position + 1
        while index < length, kind(index, big: big) == 0 { index += 1 }
        guard index < length else { return max(length - 1, 0) }
        let current = kind(index, big: big)
        while index + 1 < length, kind(index + 1, big: big) == current { index += 1 }
        return index
    }

    func previousWordStart(_ position: Int, big: Bool) -> Int {
        var index = position - 1
        while index > 0, kind(index, big: big) == 0 { index -= 1 }
        guard index > 0 else { return 0 }
        let current = kind(index, big: big)
        while index > 0, kind(index - 1, big: big) == current { index -= 1 }
        return index
    }
}
