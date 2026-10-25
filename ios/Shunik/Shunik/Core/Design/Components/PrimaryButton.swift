import SwiftUI

/// Full-width prominent action button.
///
/// Renders as a filled rectangle with a 54pt minimum height, `Theme.cornerRadius`
/// and continuous corners. This deliberately mirrors the geometry of
/// `AppleSignInButton`, which hosts Apple's `ASAuthorizationAppleIDButton` at the
/// same height and corner radius. Matching the geometry matters for two reasons:
///
/// 1. **Shape parity** — on iOS 27 the system `.borderedProminent` style renders
///    as a floating liquid-glass capsule with different corner radius/height than
///    the pinned Apple control, so the two buttons looked mismatched.
/// 2. **Keyboard animation** — the action bar lives in `safeAreaInset`, whose
///    content tracks the system keyboard transition. A fixed-height solid view
///    follows that transition cleanly, whereas the system prominent style's
///    own floating treatment animated independently ("floating behind the
///    keyboard with strange animation").
///
/// Shows a loading spinner when `isLoading` is true and disables interaction
/// when loading or explicitly disabled. Primary actions across the app use
/// this component.
struct PrimaryButton: View {
    /// The shared minimum button height (54 pt). Also referenced by
    /// `MainActionSlot` so the Track main action's fixed slot never dips
    /// below the button's own minimum.
    nonisolated static let minHeight: CGFloat = 54

    let title: String
    let icon: String?
    let isLoading: Bool
    let isDisabled: Bool
    let accessibilityId: String
    /// Optional fill override. When `nil` (the default) the button uses
    /// `Theme.accentPrimary`; pass `Theme.danger` to render a destructive
    /// primary action.
    let tint: Color?
    /// When false, state-driven content changes (tint, dimming, spinner)
    /// apply instantly instead of crossfading. Track opts out: its Start /
    /// Stop swaps must appear in place with no motion of their own.
    let animateStateChanges: Bool
    let action: () -> Void

    init(
        title: String,
        icon: String?,
        isLoading: Bool,
        isDisabled: Bool,
        accessibilityId: String,
        tint: Color? = nil,
        animateStateChanges: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isLoading = isLoading
        self.isDisabled = isDisabled
        self.accessibilityId = accessibilityId
        self.tint = tint
        self.animateStateChanges = animateStateChanges
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .tint(Theme.textOnAccent)
                } else {
                    HStack(spacing: Theme.spacingSmall) {
                        if let icon {
                            Image(systemName: icon)
                                .font(.body.bold())
                                .accessibilityHidden(true)
                        }
                        Text(title)
                            .font(.body.bold())
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: Self.minHeight)
            .foregroundStyle(Theme.textOnAccent)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        }
        .disabled(isLoading || isDisabled)
        .animation(animateStateChanges ? .easeInOut(duration: 0.15) : nil, value: isLoading || isDisabled)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(accessibilityId)
        .accessibilityLabel(title)
    }

    /// Filled background using `tint` (or `Theme.accentPrimary` when nil),
    /// dimmed to 50% alpha while the button is inactive.
    private var background: Color {
        let fill = tint ?? Theme.accentPrimary
        if isLoading || isDisabled {
            return fill.opacity(Theme.opacityDisabledFill)
        }
        return fill
    }
}

#if DEBUG
#Preview("Primary Button — Default") {
    PrimaryButton(
        title: L10n.emailEntrySubmit.text,
        icon: nil,
        isLoading: false,
        isDisabled: false,
        accessibilityId: "PreviewPrimaryButton"
    ) {}
    .padding()
}

#Preview("Primary Button — Loading") {
    PrimaryButton(
        title: L10n.emailEntrySubmit.text,
        icon: nil,
        isLoading: true,
        isDisabled: false,
        accessibilityId: "PreviewPrimaryButtonLoading"
    ) {}
    .padding()
}

#Preview("Primary Button — Disabled") {
    PrimaryButton(
        title: L10n.emailEntrySubmit.text,
        icon: nil,
        isLoading: false,
        isDisabled: true,
        accessibilityId: "PreviewPrimaryButtonDisabled"
    ) {}
    .padding()
}

#Preview("Primary Button — With Icon") {
    PrimaryButton(
        title: L10n.emailEntrySubmit.text,
        icon: "play.fill",
        isLoading: false,
        isDisabled: false,
        accessibilityId: "PreviewPrimaryButtonIcon"
    ) {}
    .padding()
}

#endif
