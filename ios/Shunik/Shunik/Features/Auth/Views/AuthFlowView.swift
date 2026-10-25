import SwiftUI

/// The auth navigation container. The welcome screen is the root; routes push
/// `EmailEntryView` and `OtpEntryView`. Sign in with Apple lives on the welcome
/// screen and flips `SessionStore` directly (no route).
struct AuthFlowView: View {
    @EnvironmentObject var container: AppContainer

    var body: some View {
        AppStack(
            stack: container.navigation,
            destination: { route in
                switch route {
                case .emailEntry:
                    EmailEntryView(vm: EmailEntryViewModel(
                        service: container.authService,
                        connectivity: container.connectivity,
                        sessionStore: container.sessionStore
                    ))
                case .otpEntry(let email):
                    OtpEntryView(vm: OtpEntryViewModel(
                        service: container.authService,
                        connectivity: container.connectivity,
                        email: email
                    ))
                }
            },
            root: {
                WelcomeView(vm: WelcomeViewModel(
                    service: container.authService,
                    appleService: container.appleService
                ))
            }
        )
        .environmentObject(container)
    }
}
