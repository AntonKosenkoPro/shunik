import AuthenticationServices
import SwiftUI
import UIKit

/// Wraps Apple's `ASAuthorizationAppleIDButton`; a transparent overlay `Button`
/// forwards taps to `action`, so the underlying control never fires its own
/// (unconfigured) target-action.
struct AppleSignInButton: View {
    let action: () -> Void

    @Environment(\.colorScheme)
    private var colorScheme

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        let style: ASAuthorizationAppleIDButton.Style = colorScheme == .dark ? .white : .black
        AppleIDButtonControl(style: style)
            .frame(height: 54)
            .overlay {
                Button(action: action) {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.appleSignInTitle.text)
                .accessibilityIdentifier("AppleSignInButton")
            }
    }
}

/// `ASAuthorizationAppleIDButton` is a UIKit `UIControl`; wrap it so SwiftUI can
/// display it. It carries no target — taps are handled by the overlay. The
/// `style` is resolved by the parent from `colorScheme` and applied in
/// `makeUIView` and propagated in `updateUIView`.
private struct AppleIDButtonControl: UIViewRepresentable {
    let style: ASAuthorizationAppleIDButton.Style

    func makeUIView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.setButton(style: style)
        return container
    }

    func updateUIView(_ uiView: ContainerView, context: Context) {
        uiView.setButton(style: style)
    }
}

/// Hosts the native `ASAuthorizationAppleIDButton`. We use a container view so we
/// can swap the underlying button when the color scheme changes; the native
/// control has no public mutable `style` property.
private final class ContainerView: UIView {
    func setButton(style: ASAuthorizationAppleIDButton.Style) {
        subviews.forEach { $0.removeFromSuperview() }
        let button = ASAuthorizationAppleIDButton(
            authorizationButtonType: .signIn,
            authorizationButtonStyle: style
        )
        button.cornerRadius = Theme.cornerRadius
        // The transparent SwiftUI overlay Button handles taps and
        // accessibility; hide the native control so VoiceOver and UI tests see
        // exactly one activatable element.
        button.isUserInteractionEnabled = false
        button.isAccessibilityElement = false
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

#if DEBUG
#Preview("Apple Sign In Button — Light") {
    AppleSignInButton { }
        .padding()
}

#Preview("Apple Sign In Button — Dark") {
    AppleSignInButton { }
        .padding()
        .preferredColorScheme(.dark)
}
#endif
