import Foundation
import SwiftUI

/// View model for the welcome screen.
///
/// The welcome screen leads with Sign in with Apple; the email/OTP path is a
/// secondary option. Apple sign-in obtains the identity token and exchanges it
/// for a session via `AuthService`; on success `SessionStore` flips and
/// `RootView` swaps the full-screen auth gate for the app shell and sync
/// activates. Cancellation is silent
/// (no error banner); other failures surface `appleSignIn.error`.
@MainActor
final class WelcomeViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let service: AuthService
    private let appleService: AppleSignInService

    init(
        service: AuthService,
        appleService: AppleSignInService
    ) {
        self.service = service
        self.appleService = appleService
    }

    /// Initiates Sign in with Apple. Runs the Apple authorization, then exchanges
    /// the identity token (plus the short-lived authorization code when Apple
    /// supplied one) for a session via `AuthService`. The native Apple user id
    /// travels separately for credential-state observation — never the Shunik
    /// UUID. Cancellation is silent (no error banner); other failures surface
    /// `appleSignIn.error`.
    func signInWithApple() async {
        isLoading = true
        errorMessage = nil

        do {
            let credential = try await appleService.signIn()
            try await service.signInWithApple(
                identityToken: credential.identityToken,
                appleUserID: credential.user,
                authorizationCode: credential.authorizationCode
            )
        } catch AppleSignInError.canceled {
            // User dismissed the Apple sheet — no error.
        } catch let error as APIError {
            errorMessage = ErrorLocalization.message(for: error)
        } catch {
            errorMessage = L10n.appleSignInError.text
        }

        isLoading = false
    }

    /// Resets transient state.
    func reset() {
        isLoading = false
        errorMessage = nil
    }
}
