import AppKit
import Carbon.HIToolbox

/// A key combination saved in user defaults.
struct Shortcut: Codable, CustomStringConvertible {
    var keyCode: UInt16
    var modifiers: UInt
    var key: String

    private static let defaultsKey = "toggleShortcut"

    static var saved: Shortcut? {
        get { UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: defaultsKey) }
    }

    /// Requires ⌘, ⌥ or ⌃ so a plain keystroke can't be stolen from every app.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isDisjoint(with: [.command, .option, .control]) else { return nil }
        keyCode = event.keyCode
        modifiers = flags.rawValue
        key = event.keyCode == kVK_Space ? "Space" : event.charactersIgnoringModifiers?.uppercased() ?? ""
    }

    private var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var description: String {
        let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { flags.contains($0.0) }.map(\.1).joined() + key
    }

    var carbonModifiers: UInt32 {
        let masks: [(NSEvent.ModifierFlags, Int)] = [(.command, cmdKey), (.option, optionKey), (.control, controlKey), (.shift, shiftKey)]
        return masks.reduce(0) { flags.contains($1.0) ? $0 | UInt32($1.1) : $0 }
    }
}

/// A system-wide hotkey. Carbon's API needs no Accessibility permission, unlike global event monitors.
@MainActor
final class GlobalHotKey {
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData!).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    func register(_ shortcut: Shortcut?) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        guard let shortcut else { return }
        let id = EventHotKeyID(signature: OSType(0x5054_4C4B), id: 1)
        RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
