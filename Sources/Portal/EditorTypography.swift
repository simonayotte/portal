import AppKit

/// All editor metrics scale from the approved 16-point appearance; chrome stays unchanged.
struct EditorTypography: Equatable, Sendable {
    static let defaultTextSize = 16.0
    static let textSizeRange = 12.0...28.0
    let textSize: Double

    init(textSize: Double = Self.defaultTextSize) {
        self.textSize = Self.validatedTextSize(textSize)
    }

    static func validatedTextSize(_ value: Double) -> Double {
        guard value.isFinite else { return defaultTextSize }
        return min(max(value, textSizeRange.lowerBound), textSizeRange.upperBound)
    }

    var scale: CGFloat { textSize / Self.defaultTextSize }
    func scaled(_ value: CGFloat) -> CGFloat { value * scale }

    func headingSize(level: Int) -> CGFloat {
        scaled([28, 23, 20, 18, 17, 16][min(max(level, 1), 6) - 1])
    }

    @MainActor var baseFont: NSFont { .systemFont(ofSize: textSize) }
    @MainActor var monoFont: NSFont { .monospacedSystemFont(ofSize: scaled(15), weight: .regular) }
}
