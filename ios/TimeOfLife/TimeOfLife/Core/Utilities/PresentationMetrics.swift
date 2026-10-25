import Foundation
import SwiftUI

extension DynamicTypeSize {
    // swiftlint:disable:next todo
    // SHUNIK-TODO: scaffold — rescued from the deleted recents chips; the
    // pet-care UI will own this mapping.
    /// The `UIContentSizeCategory` equivalent of the environment's Dynamic
    /// Type size, used to build a measurement trait collection.
    var uiContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}

/// Shared presentation-settle delay before programmatic focus (sheet push
/// and picker push alike): focusing instantly fires the keyboard
/// mid-transition and the keyboard-driven relayout jumps. One constant —
/// the former per-screen `focusDelayNanoseconds` duplicates.
enum FocusDelay {
    /// Push/sheet-transition settle before autofocus (400ms).
    static let settleNanoseconds: UInt64 = 400_000_000

    /// Sleeps through the transition settle; returns false when cancelled
    /// (popped/dismissed mid-wait) so callers skip the focus.
    @discardableResult
    static func settle() async -> Bool {
        try? await Task.sleep(nanoseconds: settleNanoseconds)
        return !Task.isCancelled
    }
}

/// Shared Dynamic Type icon-slot metrics: a fixed slot sized from the
/// scaled glyph (`basePointSize × multiplier`, ceiled) built from a trait
/// collection matching the SwiftUI environment's effective size — so slots
/// track rendering under `.dynamicTypeSize` overrides too. The former
/// per-screen `symbolSlotSize` duplicates, one idiom.
enum DynamicTypeMetrics {
    /// UITextView's default text origin: container top inset (8) plus
    /// line-fragment padding (5). Placeholder overlays on a `TextEditor`
    /// align to this origin — one source so editor text and its
    /// placeholder can never silently drift.
    static let editorTextOriginInsets = (top: CGFloat(8), leading: CGFloat(5))

    /// Fixed icon slot for a glyph of `basePointSize` at `textStyle`,
    /// widened by `multiplier` (the 1.5× slot both lists use).
    static func symbolSlotSize(
        basePointSize: CGFloat,
        textStyle: UIFont.TextStyle,
        dynamicTypeSize: DynamicTypeSize,
        multiplier: CGFloat = 1.5
    ) -> CGFloat {
        let metrics = UIFontMetrics(forTextStyle: textStyle)
        let trait = UITraitCollection(
            preferredContentSizeCategory: dynamicTypeSize.uiContentSizeCategory
        )
        let pointSize = metrics.scaledFont(
            for: UIFont.systemFont(ofSize: basePointSize),
            compatibleWith: trait
        ).pointSize
        return ceil(pointSize * multiplier)
    }
}
