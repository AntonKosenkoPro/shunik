import SwiftUI

/// OTP entry screen for passwordless authentication.
///
/// The user enters the 6-digit code sent to their email in a one-box-per-digit
/// field (`OtpCodeField`). The code auto-submits ~250 ms after the 6th digit is
/// entered so the user sees the complete code before the network call. On a
/// verification failure the code is cleared so the user can re-type. Follows
/// U1 minimalistic design with Theme semantic colors.
struct OtpEntryView: View {
    @ObservedObject var vm: OtpEntryViewModel
    @EnvironmentObject var container: AppContainer
    @State private var autoSubmitTask: Task<Void, Never>?

    var body: some View {
        // `ScrollView` gives us keyboard avoidance. The form stacks
        // from the top; content scrolls when it does not fit, especially while
        // the keyboard is open on short screens (iPhone SE 1st gen).
        ScrollView {
            VStack(spacing: Theme.spacingLarge) {
                Text(L10n.otpTitle.text)
                    .font(.title.bold())
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text(String(format: L10n.otpSentTo.text, vm.email))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer().frame(height: Theme.spacingSmall)

                OtpCodeField(
                    code: $vm.code,
                    length: 6,
                    error: vm.fieldErrors.otp,
                    isLoading: vm.isLoading,
                    accessibilityId: "OtpCodeField"
                )

                if let errorMessage = vm.errorMessage {
                    ErrorBanner(
                        message: errorMessage,
                        accessibilityId: "OtpErrorBanner"
                    )
                }

                // Resend link lives close to the OTP field because it is a
                // context action tied to the code input, not a primary
                // screen action.
                Button {
                    Task { await vm.resendOtp() }
                } label: {
                    Text(resendLabel)
                        .font(.subheadline)
                        .foregroundStyle(resendColor)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Theme.minTapArea)
                }
                .disabled(vm.isLoading || vm.resendCountdown > 0 || !container.connectivity.isConnected)
                .accessibilityIdentifier("OtpResendButton")

                // Extra breathing room below the Resend button so the
                // scrollable content ends comfortably above the keyboard on
                // short screens (iPhone SE 1st gen).
                Spacer().frame(height: Theme.spacingLarge)
            }
            .padding(.horizontal, Theme.screenHorizontalPadding)
            .padding(.vertical, Theme.spacingExtraLarge)
            .frame(maxWidth: Theme.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.backgroundPrimary.ignoresSafeArea())
        .onAppear {
            // The OTP was already requested by the email form before this
            // screen appeared, so arm the resend cooldown immediately — the
            // Resend button must be disabled from the first appearance, not
            // only after a manual resend.
            vm.armInitialResendCooldown()
        }
        .onChange(of: vm.code) { _, newValue in
            // Clear stale validation state per keystroke.
            if vm.fieldErrors.otp != nil {
                vm.fieldErrors.otp = nil
            }

            // Auto-submit after the 6th digit, debounced so the user sees the
            // full code before the network call. A shorter/changed code cancels
            // any pending auto-submit. The field stays first responder (we do
            // not dismiss the keyboard); on success `AuthService` flips
            // `SessionStore` to signed-in; the launch gate swaps to the app
            // shell.
            autoSubmitTask?.cancel()
            guard newValue.count == 6 else { return }
            autoSubmitTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, vm.code.count == 6, !vm.isLoading else { return }
                await vm.submit()
            }
        }
        .onDisappear {
            autoSubmitTask?.cancel()
        }
    }

    /// Label for the Resend button: shows the plain call-to-action while it is
    /// tappable, and a live countdown while the client-side cooldown is active.
    private var resendLabel: String {
        if vm.resendCountdown > 0 {
            return String(format: L10n.otpResendCountdown.text, vm.resendCountdown)
        }
        return L10n.otpResend.text
    }

    /// Dimmed appearance whenever the button is disabled (cooldown, loading,
    /// or offline) so the user has a visual affordance that resend is unavailable.
    private var resendColor: Color {
        let disabled = vm.isLoading || vm.resendCountdown > 0 || !container.connectivity.isConnected
        return disabled
            ? Theme.accentPrimary.opacity(Theme.opacityDisabledFill)
            : Theme.accentPrimary
    }
}

#if DEBUG
#Preview("OTP Entry — EN Light") {
    let container = AppContainer.production()
    OtpEntryView(vm: OtpEntryViewModel(
        service: container.authService,
        connectivity: container.connectivity,
        email: "preview@example.com"
    ))
    .environmentObject(container.navigation)
    .environmentObject(container)
}

#Preview("OTP Entry — RU Dark") {
    let container = AppContainer.production()
    OtpEntryView(vm: OtpEntryViewModel(
        service: container.authService,
        connectivity: container.connectivity,
        email: "preview@example.com"
    ))
    .environmentObject(container.navigation)
    .environmentObject(container)
    .preferredColorScheme(.dark)
    .environment(\.locale, .init(identifier: "ru"))
}
#endif
