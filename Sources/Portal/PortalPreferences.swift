import Combine
import Foundation

@MainActor
final class PortalPreferences: ObservableObject {
    static let shared = PortalPreferences(defaults: .standard)
    nonisolated static let defaultBackgroundOpacity = 0.15
    nonisolated static let backgroundOpacityRange = 0.0...1.0

    enum Key {
        static let editorTextSize = "editorTextSize"
        static let backgroundOpacity = "backgroundOpacity"
    }

    private let defaults: UserDefaults
    @Published private var textSize: Double
    @Published private var opacity: Double

    var editorTextSize: Double {
        get { textSize }
        set {
            textSize = EditorTypography.validatedTextSize(newValue)
            defaults.set(textSize, forKey: Key.editorTextSize)
        }
    }

    /// The solid system-color overlay, not the opacity of the underlying HUD material.
    var backgroundOpacity: Double {
        get { opacity }
        set {
            opacity = Self.validatedBackgroundOpacity(newValue)
            defaults.set(opacity, forKey: Key.backgroundOpacity)
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        textSize = EditorTypography.validatedTextSize(
            Self.number(defaults.object(forKey: Key.editorTextSize)) ?? EditorTypography.defaultTextSize
        )
        opacity = Self.validatedBackgroundOpacity(
            Self.number(defaults.object(forKey: Key.backgroundOpacity)) ?? Self.defaultBackgroundOpacity
        )
        // Repair invalid saved values without populating defaults merely by reading them.
        if defaults.object(forKey: Key.editorTextSize) != nil {
            defaults.set(textSize, forKey: Key.editorTextSize)
        }
        if defaults.object(forKey: Key.backgroundOpacity) != nil {
            defaults.set(opacity, forKey: Key.backgroundOpacity)
        }
    }

    nonisolated static func validatedBackgroundOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultBackgroundOpacity }
        return min(max(value, backgroundOpacityRange.lowerBound), backgroundOpacityRange.upperBound)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}
