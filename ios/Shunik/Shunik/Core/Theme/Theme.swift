import SwiftUI

/// Semantic design tokens. Colors are resolved from the asset catalog so
/// light/dark (U2) and system color scheme are respected. Views never use
/// raw `Color(...)` literals or magic numbers — only `Theme.*`.
enum Theme {
    // MARK: - Colors

    static let backgroundPrimary = Color("BackgroundPrimary", bundle: .main)
    static let backgroundSecondary = Color("BackgroundSecondary", bundle: .main)
    static let textPrimary = Color("TextPrimary", bundle: .main)
    static let textSecondary = Color("TextSecondary", bundle: .main)
    static let accentPrimary = Color("AccentPrimary", bundle: .main)
    static let danger = Color("Danger", bundle: .main)
    static let hairline = Color("Hairline", bundle: .main)
    static let textOnAccent = Color.white
    static let transparent = Color.clear

    // MARK: - Spacing

    static let spacingExtraSmall: CGFloat = 4
    static let spacingSmall: CGFloat = 8
    static let spacingChip: CGFloat = 10
    static let spacingMedium: CGFloat = 16
    static let spacingLarge: CGFloat = 24
    static let spacingExtraLarge: CGFloat = 32

    // MARK: - Layout

    static let cornerRadius: CGFloat = 10
    static let cornerRadiusSmall: CGFloat = 8
    static let minTapArea: CGFloat = 44
    static let screenHorizontalPadding: CGFloat = 24
    static let maxContentWidth: CGFloat = 420

    // MARK: - Opacity

    /// Dimmed fill for inactive (loading/disabled) primary buttons.
    static let opacityDisabledFill: Double = 0.5
    /// Soft accent wash for active pills.
    static let opacityAccentSoft: Double = 0.15
    /// Faint accent wash for the compact-timer icon disc.
    static let opacityAccentFaint: Double = 0.13
    /// Dimmed trailing clear glyph.
    static let opacityClearGlyph: Double = 0.55
    /// Locked (read-only) form cards.
    static let opacityLockedForm: Double = 0.6
    /// Fully transparent hidden capture field.
    static let opacityHiddenField: Double = 0

    // MARK: - Helpers

    /// Returns a font suitable for the large timer display.
    static func timerFont() -> Font {
        .system(size: 64, weight: .semibold, design: .rounded)
    }
}
