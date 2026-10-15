import SwiftUI

/// Shared card chrome for the entry-form cards (entry-editor spec): rounded
/// secondary-background card with tap-away keyboard dismissal.
///
/// The tap-away lives on the card's *background layer*, never on the card
/// itself: hit-testing gives interactive children first claim, so taps on
/// `Button`s (TagSelector chips, date/time pills, the name-row link) and on
/// UIKit-backed controls like the graphical calendar grid always reach
/// those controls. A card-wide `.onTapGesture` recognizer sits above the
/// calendar in the responder chain and swallows its day-cell touches
/// (fix-entry-date-picker-taps) — the background placement is what keeps
/// that from happening. Only taps landing on genuinely empty card area
/// (labels, padding, background — none of which claim hits) fall through
/// to the background and resign focus, which is exactly the spec'd
/// tap-away contract. Every control that must dismiss the keyboard still
/// resigns explicitly in its own action (issue #67: the Notes `×`
/// deliberately does NOT resign — it clears only, so no flicker and no
/// race is possible).
///
/// The notes editor uses this too: tapping the `TextEditor` itself
/// keeps working — the editor's focus claim is applied after the tap
/// gesture's resign, so the editor still wins focus, while taps anywhere
/// else on the card (label, padding) dismiss the keyboard.
struct FormCard<Content: View>: View {
    private let accessibilityID: String?
    private let resignFocus: () -> Void
    private let content: () -> Content

    /// - Parameter resignFocus: Autoclosure (not a closure literal) so call
    ///   sites keep single-trailing-closure form per
    ///   `multiple_closures_with_trailing_closure`, e.g.
    ///   `resignFocus: focusedField = nil`.
    init(
        accessibilityID: String? = nil,
        resignFocus: @autoclosure @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.accessibilityID = accessibilityID
        self.resignFocus = resignFocus
        self.content = content
    }

    var body: some View {
        Group {
            if let accessibilityID {
                chrome.accessibilityIdentifier(accessibilityID)
            } else {
                chrome
            }
        }
    }

    private var chrome: some View {
        content()
            .padding(Theme.spacingMedium)
            .background(
                Theme.backgroundSecondary
                    .onTapGesture {
                        resignFocus()
                    }
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}
