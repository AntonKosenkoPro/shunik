import SwiftUI

/// Email entry screen for passwordless authentication.
///
/// The user enters their email address and taps "Continue" (or presses the
/// keyboard Return key) to receive a one-time passcode. Validation is performed
/// locally before the network request. Sign in with Apple lives on the welcome
/// screen, not here. Follows U1 minimalistic design with Theme semantic colors.
struct EmailEntryView: View {
    @ObservedObject var vm: EmailEntryViewModel
    @EnvironmentObject var navigation: AppNavigationStack
    @FocusState private var isEmailFocused: Bool
    @State private var bottomBarHeight: CGFloat = 0

    var body: some View {
        // `ScrollView` + `.safeAreaInset(edge: .bottom)` gives us keyboard
        // avoidance. The form stacks from the top with a fixed reserve
        // for the pinned bottom action bar so the field never crowds the buttons
        // on short screens (iPhone SE 1st gen), especially while the keyboard
        // is open. Content scrolls when it does not fit.
        ScrollView {
            VStack(spacing: Theme.spacingLarge) {
                Text(L10n.emailEntryTitle.text)
                    .font(.title.bold())
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text(L10n.emailEntrySubtitle.text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer().frame(height: Theme.spacingSmall)

                TextFieldWithError(
                    title: L10n.emailEntryEmail.text,
                    placeholder: L10n.emailEntryEmail.text,
                    text: $vm.email,
                    error: vm.fieldErrors.email,
                    keyboardType: .emailAddress,
                    textContentType: .emailAddress,
                    submitLabel: .continue,
                    autocapitalization: .none,
                    accessibilityId: "EmailField",
                    onSubmit: submit,
                    focused: $isEmailFocused
                )
                .disabled(vm.isLoading)

                if let errorMessage = vm.errorMessage {
                    ErrorBanner(
                        message: errorMessage,
                        accessibilityId: "EmailErrorBanner"
                    )
                }

                // Extra breathing room between the input/error and the
                // pinned bottom action bar. This space is part of the
                // scrollable content, so when the keyboard scrolls the
                // field into view it leaves a comfortable gap above the
                // Continue button on short screens (iPhone SE 1st gen).
                Spacer().frame(height: Theme.spacingLarge)

                // Fixed reserve for the pinned bottom action bar plus
                // margin so the scrollable content ends well above the
                // buttons on every screen size, even with the keyboard up.
                Color.clear.frame(height: bottomBarHeight + Theme.spacingLarge)
            }
            .padding(.horizontal, Theme.screenHorizontalPadding)
            .padding(.top, Theme.spacingExtraLarge)
            .frame(maxWidth: Theme.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.backgroundPrimary.ignoresSafeArea())
        .measuredBottomBar(height: $bottomBarHeight) {
            // Pinned action bar. Content in `safeAreaInset` animates with the
            // system keyboard transition instead of reflowing with the main
            // stack, and stays visible above the keyboard so the user can tap
            // Continue without dismissing the keyboard first. The enclosing
            // `ScrollView` makes this inset lift above the keyboard (it was
            // covered on iPhone SE 1st gen).
            VStack(spacing: Theme.spacingSmall) {
                PrimaryButton(
                    title: L10n.emailEntrySubmit.text,
                    icon: nil,
                    isLoading: vm.isLoading,
                    isDisabled: vm.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    accessibilityId: "EmailContinueButton",
                    action: submit
                )
            }
            .padding(.horizontal, Theme.screenHorizontalPadding)
            .padding(.vertical, Theme.spacingSmall)
            .frame(maxWidth: Theme.maxContentWidth)
            .frame(maxWidth: .infinity)
            .background(Theme.backgroundPrimary)
        }
        .onAppear { isEmailFocused = true }
        .onChange(of: vm.email) {
            if vm.fieldErrors.email != nil {
                vm.fieldErrors.email = nil
            }
            if vm.errorMessage != nil {
                vm.errorMessage = nil
            }
        }
        .onChange(of: vm.isEmailSent) { _, sent in
            if sent {
                navigation.push(.otpEntry(email: vm.email))
                vm.isEmailSent = false
            }
        }
    }

    private func submit() {
        isEmailFocused = false
        Task { await vm.submit() }
    }
}

#if DEBUG
#Preview("Email Entry — EN Light") {
    let container = AppContainer.production()
    EmailEntryView(vm: EmailEntryViewModel(
        service: container.authService,
        connectivity: container.connectivity
    ))
    .environmentObject(container.navigation)
    .environmentObject(container)
}

#Preview("Email Entry — RU Dark") {
    let container = AppContainer.production()
    EmailEntryView(vm: EmailEntryViewModel(
        service: container.authService,
        connectivity: container.connectivity
    ))
    .environmentObject(container.navigation)
    .environmentObject(container)
    .preferredColorScheme(.dark)
    .environment(\.locale, .init(identifier: "ru"))
}
#endif
