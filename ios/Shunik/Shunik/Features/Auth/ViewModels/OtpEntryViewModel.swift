import Foundation
import SwiftUI

/// View model for the OTP entry screen.
///
/// Validates the code locally (6 digits) and delegates verification to
/// `AuthService`. The user reads the 6-digit code from the email and types it;
/// there is no magic link / deep link.
@MainActor
final class OtpEntryViewModel: ObservableObject {
    /// Seconds remaining before the user may request another code. While > 0
    /// the Resend button is disabled and shows this count. Driven by
    /// `resendCountdownTask`.
    static let resendCooldownSeconds: Int = 30

    @Published var code: String = ""
    @Published var fieldErrors: FieldErrors = .empty
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var resendCountdown: Int = 0

    let email: String
    private let service: AuthService
    private let connectivity: Connectivity
    private var resendCountdownTask: Task<Void, Never>?
    private var initialCooldownArmed = false

    init(service: AuthService, connectivity: Connectivity, email: String) {
        self.service = service
        self.connectivity = connectivity
        self.email = email
    }

    /// Arms the resend cooldown once, reflecting that an OTP was already
    /// requested by the email form before this screen appeared. Idempotent so
    /// a re-appearance (e.g. a transient `onAppear` re-fire) never restarts the
    /// timer. The initial `requestOtp` happened upstream, so the user should be
    /// rate-limited from the moment they land here — not only after a manual
    /// resend.
    func armInitialResendCooldown() {
        guard !initialCooldownArmed else { return }
        initialCooldownArmed = true
        startResendCountdown()
    }

    /// Validates the OTP code and returns `true` if valid.
    func validateCode() -> Bool {
        let errors = AuthValidator.validateOtpCode(code)
        fieldErrors.otp = AuthValidator.unifiedOtpMessage(errors)
        return errors.isEmpty
    }

    /// Submits the OTP verification. On success `AuthService` updates
    /// `SessionStore`, which drives the signed-in transition in `RootView`.
    func submit() async {
        guard connectivity.isConnected else {
            errorMessage = String.localized("error.offline")
            return
        }

        guard validateCode() else { return }

        isLoading = true
        errorMessage = nil

        do {
            try await service.verifyOtp(email: email, code: code)
        } catch let error as APIError {
            errorMessage = ErrorLocalization.message(for: error)
            // Clear the code so the user can re-type immediately after a
            // verification failure. Offline never reaches this path.
            code = ""
        } catch {
            errorMessage = String.localized("error.unknown")
            code = ""
        }

        isLoading = false
    }

    /// Resends the OTP code to the same email.
    ///
    /// Rate-limited client-side to one request per `resendCooldownSeconds`:
    /// while the countdown is active the call is a no-op (the view also
    /// disables the button). The countdown only starts after a successful
    /// resend, so a failed attempt (e.g. offline or server error) leaves the
    /// button tappable for an immediate retry.
    ///
    /// Clears the existing code and field error before the network call so the
    /// user can type the fresh code and any pending auto-submit is cancelled.
    func resendOtp() async {
        guard resendCountdown == 0 else { return }

        guard connectivity.isConnected else {
            errorMessage = String.localized("error.offline")
            return
        }

        isLoading = true
        errorMessage = nil
        fieldErrors.otp = nil
        code = ""

        do {
            try await service.requestOtp(email: email)
            startResendCountdown()
        } catch let error as APIError {
            errorMessage = ErrorLocalization.message(for: error)
        } catch {
            errorMessage = String.localized("error.unknown")
        }

        isLoading = false
    }

    /// Starts the client-side resend cooldown, ticking `resendCountdown` down
    /// once per second until it reaches 0. Cancels any in-flight countdown
    /// first so rapid taps (or re-arming) never stack tasks.
    private func startResendCountdown() {
        resendCountdownTask?.cancel()
        resendCountdown = Self.resendCooldownSeconds
        let seconds = Self.resendCooldownSeconds
        resendCountdownTask = Task { [weak self] in
            for remaining in stride(from: seconds - 1, through: 0, by: -1) {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                self.resendCountdown = remaining
            }
        }
    }

    /// Resets the form.
    func reset() {
        code = ""
        fieldErrors = .empty
        isLoading = false
        errorMessage = nil
        resendCountdownTask?.cancel()
        resendCountdownTask = nil
        resendCountdown = 0
    }
}
