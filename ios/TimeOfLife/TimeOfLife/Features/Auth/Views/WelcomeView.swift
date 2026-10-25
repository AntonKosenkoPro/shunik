import SwiftUI

/// Welcome screen — the root of the mandatory launch gate (app-shell spec,
/// account-bound-local-data).
///
/// Introduces the app ("Shunik — pet care companion") and leads with
/// Sign in with Apple as the primary, default auth method. Email/OTP is a
/// secondary option reached via a plain text button that pushes `.emailEntry`.
/// The email button is always tappable (it only navigates); it is disabled only
/// while an Apple sign-in attempt is in flight to prevent concurrent auth flows.
/// No text entry on this screen, so there is no keyboard handling.
///
/// Presented full-screen at the root — never a sheet — so there is no
/// dismiss/Cancel path: the gate cannot be left without signing in.
struct WelcomeView: View {
    @ObservedObject var vm: WelcomeViewModel
    @EnvironmentObject var navigation: AppNavigationStack
    @EnvironmentObject var container: AppContainer

    private var isOffline: Bool { !container.connectivity.isConnected }
    private var appleButtonDisabled: Bool { isOffline || vm.isLoading }
    private var emailButtonDisabled: Bool { vm.isLoading }

    var body: some View {
        ScrollView {

            VStack(spacing: Theme.spacingLarge) {
                Spacer(minLength: Theme.spacingExtraLarge)

                // Decorative brand mark; hidden from VoiceOver.
                Image("BrandMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 68)
                    .foregroundStyle(Theme.accentPrimary)
                    .accessibilityHidden(true)

                Text(L10n.appName.text)
                    .font(.largeTitle.bold())
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text(L10n.welcomeTagline.text)
                    .font(.headline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorMessage = vm.errorMessage {
                    ErrorBanner(
                        message: errorMessage,
                        accessibilityId: "WelcomeErrorBanner"
                    )
                }

                // Extra breathing room above the pinned bottom action bar.
                Spacer().frame(height: Theme.spacingExtraLarge)

                // Fixed reserve so the scrollable content ends above the bar.
                Color.clear.frame(height: bottomBarHeight + Theme.spacingLarge)
            }
            .padding(.horizontal, Theme.screenHorizontalPadding)
            .frame(maxWidth: Theme.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.backgroundPrimary.ignoresSafeArea())
        .measuredBottomBar(height: $bottomBarHeight) {
            VStack(spacing: Theme.spacingSmall) {
                Spacer().frame(height: Theme.spacingLarge)

                AppleSignInButton {
                    Task { await vm.signInWithApple() }
                }
                .disabled(appleButtonDisabled)
                .opacity(appleButtonDisabled ? 0.6 : 1)
                .animation(.easeInOut(duration: 0.15), value: appleButtonDisabled)
                
                Spacer().frame(height: Theme.spacingSmall)
                
                Button {
                    navigation.push(.emailEntry)
                } label: {
                    Text(L10n.welcomeContinueWithEmail.text)
                        .font(.subheadline)
                        .foregroundStyle(Theme.accentPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Theme.minTapArea)
                }
                .disabled(emailButtonDisabled)
                .accessibilityIdentifier("WelcomeContinueWithEmailButton")
            }
            .padding(.horizontal, Theme.screenHorizontalPadding)
            .padding(.vertical, Theme.spacingSmall)
            .frame(maxWidth: Theme.maxContentWidth)
            .frame(maxWidth: .infinity)
            .background(Theme.backgroundPrimary)
        }
        .onAppear { vm.reset() }
        // Full-screen gate chrome (app-shell spec): the title states the
        // requirement in the required voice. The flow sets no Cancel item —
        // there is no dismiss path out of the gate without signing in.
        // The title also renders the bar, since a titleless
        // NavigationStack shows no bar at all. Pushed screens keep the title
        // with their Back button; swipe-to-dismiss of pushed screens still
        // works throughout.
        .navigationTitle(L10n.authGateTitle.text)
        .navigationBarTitleDisplayMode(.inline)
    }

    @State private var bottomBarHeight: CGFloat = 0
}

#if DEBUG
#Preview("Welcome — EN Light") {
    let container = AppContainer.production()
    WelcomeView(vm: WelcomeViewModel(
        service: container.authService,
        appleService: container.appleService
    ))
    .environmentObject(container.navigation)
    .environmentObject(container)
}

#Preview("Welcome — RU Dark") {
    let container = AppContainer.production()
    WelcomeView(vm: WelcomeViewModel(
        service: container.authService,
        appleService: container.appleService
    ))
    .environmentObject(container.navigation)
    .environmentObject(container)
    .preferredColorScheme(.dark)
    .environment(\.locale, .init(identifier: "ru"))
}
#endif
