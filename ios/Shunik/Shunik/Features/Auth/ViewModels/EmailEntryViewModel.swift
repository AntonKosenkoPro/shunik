import Foundation
import SwiftUI

/// View model for the email entry screen.
///
/// Validates the email locally before hitting the network, normalizes it
/// (trim + lowercase), and delegates the request to `AuthService`. Sign in with
/// Apple is no longer on this screen — it lives on the welcome screen.
@MainActor
final class EmailEntryViewModel: ObservableObject {
    @Published var email: String = ""
    @Published var fieldErrors: FieldErrors = .empty
    @Published var isLoading = false
    @Published var isEmailSent = false
    @Published var errorMessage: String?

    private let service: AuthService
    private let connectivity: Connectivity
    private let sessionStore: SessionStore

    /// `sessionStore` defaults to a fresh store but production injects the shared
    /// one so the email field can be restored from `cachedEmail` when the user
    /// navigates back here from the OTP screen (a fresh view model is created on
    /// each appearance).
    init(
        service: AuthService,
        connectivity: Connectivity,
        sessionStore: SessionStore = SessionStore()
    ) {
        self.service = service
        self.connectivity = connectivity
        self.sessionStore = sessionStore
        if let cached = sessionStore.cachedEmail, !cached.isEmpty {
            email = cached
        }
    }

    /// Validates the email field and returns `true` if valid.
    func validateEmail() -> Bool {
        let errors = AuthValidator.validateEmail(email)
        fieldErrors.email = AuthValidator.unifiedEmailMessage(errors)
        return errors.isEmpty
    }

    /// Submits the OTP request. Validates first; on success sets `isEmailSent`.
    func submit() async {
        guard connectivity.isConnected else {
            errorMessage = String.localized("error.offline")
            return
        }

        guard validateEmail() else { return }

        isLoading = true
        errorMessage = nil

        do {
            try await service.requestOtp(email: email)
            isEmailSent = true
        } catch let error as APIError {
            errorMessage = ErrorLocalization.message(for: error)
        } catch {
            errorMessage = String.localized("error.unknown")
        }

        isLoading = false
    }
}
