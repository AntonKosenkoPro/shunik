import Testing
import Foundation
@testable import Shunik

@MainActor
@Suite("OtpEntryViewModel")
struct OtpEntryViewModelTests {

    // MARK: - Validation & submit

    @Test("OtpEntryViewModel: invalid code blocks submit")
    func otpEntryValidation() async throws {
        let (service, repo, conn, store) = TestFactories.makeService()
        let vm = OtpEntryViewModel(service: service, connectivity: conn, email: "a@b.com")
        vm.code = "12345"

        await vm.submit()

        #expect(repo.calls.isEmpty)
        #expect(vm.fieldErrors.otp != nil)
        #expect(store.state == .signedOut)
    }

    @Test("OtpEntryViewModel: empty code shows validation error")
    func otpEntryEmptyCode() async throws {
        let (service, repo, conn, _) = TestFactories.makeService()
        let vm = OtpEntryViewModel(service: service, connectivity: conn, email: "a@b.com")
        vm.code = ""

        await vm.submit()

        #expect(repo.calls.isEmpty)
        #expect(vm.fieldErrors.otp != nil)
    }

    @Test("OtpEntryViewModel: invalid_otp error sets errorMessage")
    func otpEntryInvalidOtp() async throws {
        let repo = FakeAuthRepository()
        repo.otpVerifyError = APIError.server(code: "invalid_otp", message: "Incorrect code. Try again.")
        let (service, _, conn, store) = TestFactories.makeService(repo: repo)
        let vm = OtpEntryViewModel(service: service, connectivity: conn, email: "a@b.com")
        vm.code = "123456"

        await vm.submit()

        #expect(repo.calls == [.verifyOtp(email: "a@b.com", code: "123456")])
        #expect(vm.errorMessage != nil)
        #expect(store.state == .signedOut)
    }

    @Test("OtpEntryViewModel: verification failure clears the code so the user can retype")
    func otpEntryClearsCodeOnError() async throws {
        let repo = FakeAuthRepository()
        repo.otpVerifyError = APIError.server(code: "invalid_otp", message: "Incorrect code. Try again.")
        let (service, _, conn, _) = TestFactories.makeService(repo: repo)
        let vm = OtpEntryViewModel(service: service, connectivity: conn, email: "a@b.com")
        vm.code = "123456"

        await vm.submit()

        #expect(vm.errorMessage != nil)
        #expect(vm.code.isEmpty)
    }

    @Test("OtpEntryViewModel: otp_expired error sets errorMessage")
    func otpEntryExpired() async throws {
        let repo = FakeAuthRepository()
        repo.otpVerifyError = APIError.server(code: "otp_expired", message: "This code has expired.")
        let (service, _, conn, store) = TestFactories.makeService(repo: repo)
        let vm = OtpEntryViewModel(service: service, connectivity: conn, email: "a@b.com")
        vm.code = "123456"

        await vm.submit()

        #expect(vm.errorMessage != nil)
        #expect(store.state == .signedOut)
    }

    @Test("OtpEntryViewModel: otp_attempts_exceeded error sets errorMessage")
    func otpEntryAttemptsExceeded() async throws {
        let repo = FakeAuthRepository()
        repo.otpVerifyError = APIError.server(
            code: "otp_attempts_exceeded",
            message: "Too many attempts. Request a new code."
        )
        let (service, _, conn, store) = TestFactories.makeService(repo: repo)
        let vm = OtpEntryViewModel(service: service, connectivity: conn, email: "a@b.com")
        vm.code = "123456"

        await vm.submit()

        #expect(vm.errorMessage != nil)
        #expect(store.state == .signedOut)
    }

    @Test("OtpEntryViewModel: success signs the user in via SessionStore")
    func otpEntrySuccess() async throws {
        let (service, repo, conn, store) = TestFactories.makeService()
        let vm = OtpEntryViewModel(service: service, connectivity: conn, email: "a@b.com")
        vm.code = "123456"

        await vm.submit()

        #expect(repo.calls == [.verifyOtp(email: "a@b.com", code: "123456")])
        #expect(vm.errorMessage == nil)
        if case .signedIn = store.state {
            // Success
        } else {
            Issue.record("Expected signed in state")
        }
    }

    @Test("OtpEntryViewModel: offline blocks submit and shows error")
    func otpEntryOffline() async throws {
        let (service, repo, _, store) = TestFactories.makeService()
        let conn = Connectivity()
        conn.isConnected = false
        let vm = OtpEntryViewModel(service: service, connectivity: conn, email: "a@b.com")
        vm.code = "123456"

        await vm.submit()

        #expect(repo.calls.isEmpty)
        #expect(vm.errorMessage != nil)
        #expect(store.state == .signedOut)
    }

    // MARK: - Resend & cooldown

    @Test("OtpEntryViewModel: resendOtp calls requestOtp for the same email")
    func otpEntryResend() async throws {
        let (service, repo, conn, _) = TestFactories.makeService()
        let vm = OtpEntryViewModel(service: service, connectivity: conn, email: "a@b.com")

        await vm.resendOtp()

        #expect(repo.calls == [.requestOtp(email: "a@b.com")])
        #expect(vm.errorMessage == nil)
    }

    @Test("OtpEntryViewModel: resend clears the existing code and field error")
    func otpEntryResendClearsCode() async throws {
        let (service, repo, conn, _) = TestFactories.makeService()
        let vm = OtpEntryViewModel(service: service, connectivity: conn, email: "a@b.com")
        vm.code = "123456"
        vm.fieldErrors.otp = "Old error"

        await vm.resendOtp()

        #expect(vm.code.isEmpty)
        #expect(vm.fieldErrors.otp == nil)
        #expect(repo.calls == [.requestOtp(email: "a@b.com")])
    }

    @Test("OtpEntryViewModel: arming the initial cooldown disables resend on appear")
    func otpEntryArmInitialCooldown() async throws {
        let (service, _, conn, _) = TestFactories.makeService()
        let vm = OtpEntryViewModel(service: service, connectivity: conn, email: "a@b.com")

        // The OTP was already requested by the email form, so appearing here
        // should arm the cooldown immediately — without a manual resend.
        #expect(vm.resendCountdown == 0)
        vm.armInitialResendCooldown()
        #expect(vm.resendCountdown == OtpEntryViewModel.resendCooldownSeconds)

        // Idempotent: a re-appearance must not restart the timer.
        vm.armInitialResendCooldown()
        #expect(vm.resendCountdown == OtpEntryViewModel.resendCooldownSeconds)
    }

    @Test("OtpEntryViewModel: armed cooldown blocks a manual resend")
    func otpEntryArmInitialCooldownBlocksResend() async throws {
        let (service, repo, conn, _) = TestFactories.makeService()
        let vm = OtpEntryViewModel(service: service, connectivity: conn, email: "a@b.com")

        vm.armInitialResendCooldown()
        await vm.resendOtp()

        // Cooldown was armed on appear, so the resend is rate-limited and never
        // reaches the repo.
        #expect(repo.calls.isEmpty)
        #expect(vm.resendCountdown == OtpEntryViewModel.resendCooldownSeconds)
    }

    @Test("OtpEntryViewModel: resendOtp shows error on failure")
    func otpEntryResendFailure() async throws {
        let repo = FakeAuthRepository()
        repo.otpRequestError = APIError.server(code: "rate_limited", message: "Too many attempts.")
        let (service, _, conn, _) = TestFactories.makeService(repo: repo)
        let vm = OtpEntryViewModel(service: service, connectivity: conn, email: "a@b.com")

        await vm.resendOtp()

        #expect(vm.errorMessage != nil)
    }

    @Test("OtpEntryViewModel: successful resend starts the cooldown countdown")
    func otpEntryResendStartsCooldown() async throws {
        let (service, repo, conn, _) = TestFactories.makeService()
        let vm = OtpEntryViewModel(service: service, connectivity: conn, email: "a@b.com")

        await vm.resendOtp()

        #expect(repo.calls == [.requestOtp(email: "a@b.com")])
        #expect(vm.resendCountdown == OtpEntryViewModel.resendCooldownSeconds)
    }

    @Test("OtpEntryViewModel: resend is a no-op while the cooldown is active")
    func otpEntryResendBlockedDuringCooldown() async throws {
        let (service, repo, conn, _) = TestFactories.makeService()
        let vm = OtpEntryViewModel(service: service, connectivity: conn, email: "a@b.com")

        await vm.resendOtp()
        // A successful resend arms the cooldown to its full duration synchronously,
        // so a second immediate tap is rate-limited and never reaches the repo.
        #expect(vm.resendCountdown == OtpEntryViewModel.resendCooldownSeconds)
        await vm.resendOtp()

        #expect(repo.calls == [.requestOtp(email: "a@b.com")])
        #expect(vm.resendCountdown == OtpEntryViewModel.resendCooldownSeconds)
    }

    @Test("OtpEntryViewModel: failed resend does not start the cooldown")
    func otpEntryResendFailureNoCooldown() async throws {
        let repo = FakeAuthRepository()
        repo.otpRequestError = APIError.server(code: "rate_limited", message: "Too many attempts.")
        let (service, _, conn, _) = TestFactories.makeService(repo: repo)
        let vm = OtpEntryViewModel(service: service, connectivity: conn, email: "a@b.com")

        await vm.resendOtp()

        #expect(vm.resendCountdown == 0)
    }

    @Test("OtpEntryViewModel: reset clears the cooldown")
    func otpEntryResetClearsCooldown() async throws {
        let (service, _, conn, _) = TestFactories.makeService()
        let vm = OtpEntryViewModel(service: service, connectivity: conn, email: "a@b.com")

        await vm.resendOtp()
        #expect(vm.resendCountdown > 0)

        vm.reset()

        #expect(vm.resendCountdown == 0)
    }

    // MARK: - Reset

    @Test("OtpEntryViewModel: reset clears all state")
    func otpEntryReset() async throws {
        let (service, _, conn, _) = TestFactories.makeService()
        let vm = OtpEntryViewModel(service: service, connectivity: conn, email: "a@b.com")
        vm.code = "123456"
        vm.fieldErrors.otp = "Error"
        vm.isLoading = true
        vm.errorMessage = "Error"

        vm.reset()

        #expect(vm.code.isEmpty)
        #expect(vm.fieldErrors.isEmpty)
        #expect(vm.isLoading == false)
        #expect(vm.errorMessage == nil)
    }
}
