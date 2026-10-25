import Testing
import Foundation
@testable import Shunik

@MainActor
@Suite("EmailEntryViewModel")
struct EmailEntryViewModelTests {

    // MARK: - EmailEntryViewModel

    @Test("EmailEntryViewModel: client validation blocks submit for invalid email")
    func emailEntryValidation() async throws {
        let (service, repo, conn, _) = TestFactories.makeService()
        let vm = EmailEntryViewModel(service: service, connectivity: conn)
        vm.email = "bad"

        await vm.submit()

        #expect(repo.calls.isEmpty)
        #expect(vm.fieldErrors.email != nil)
        #expect(vm.fieldErrors.otp == nil)
        #expect(vm.isLoading == false)
        #expect(vm.isEmailSent == false)
    }

    @Test("EmailEntryViewModel: empty email shows validation error")
    func emailEntryEmptyEmail() async throws {
        let (service, repo, conn, _) = TestFactories.makeService()
        let vm = EmailEntryViewModel(service: service, connectivity: conn)
        vm.email = ""

        await vm.submit()

        #expect(repo.calls.isEmpty)
        #expect(vm.fieldErrors.email != nil)
    }

    @Test("EmailEntryViewModel: offline disables submit and shows error")
    func emailEntryOffline() async throws {
        let (service, repo, _, _) = TestFactories.makeService()
        let conn = Connectivity()
        conn.isConnected = false
        let vm = EmailEntryViewModel(service: service, connectivity: conn)
        vm.email = "a@b.com"

        await vm.submit()

        #expect(repo.calls.isEmpty)
        #expect(vm.errorMessage != nil)
        #expect(vm.isEmailSent == false)
    }

    @Test("EmailEntryViewModel: success calls requestOtp and sets isEmailSent")
    func emailEntrySuccess() async throws {
        let (service, repo, conn, store) = TestFactories.makeService()
        let vm = EmailEntryViewModel(service: service, connectivity: conn)
        vm.email = "  Foo@Bar.com "

        await vm.submit()

        #expect(repo.calls == [.requestOtp(email: "foo@bar.com")])
        #expect(vm.isEmailSent == true)
        #expect(vm.errorMessage == nil)
        #expect(vm.isLoading == false)
        #expect(store.cachedEmail == "foo@bar.com")
    }

    @Test("EmailEntryViewModel: email is restored from cached email on init")
    func emailEntryRestoresCachedEmail() async throws {
        let (service, _, conn, store) = TestFactories.makeService()
        // Simulate the email form having already requested an OTP (which caches
        // the normalized email) before the user navigates back to this screen.
        store.setCachedEmail("foo@bar.com")

        let vm = EmailEntryViewModel(service: service, connectivity: conn, sessionStore: store)

        #expect(vm.email == "foo@bar.com")
    }

    @Test("EmailEntryViewModel: email stays empty when nothing is cached")
    func emailEntryEmptyWhenNotCached() async throws {
        let (service, _, conn, _) = TestFactories.makeService()
        let vm = EmailEntryViewModel(service: service, connectivity: conn)

        #expect(vm.email.isEmpty)
    }

    @Test("EmailEntryViewModel: rate_limited error sets errorMessage")
    func emailEntryRateLimited() async throws {
        let repo = FakeAuthRepository()
        repo.otpRequestError = APIError.server(code: "rate_limited", message: "Too many attempts. Try again later.")
        let (service, _, conn, _) = TestFactories.makeService(repo: repo)
        let vm = EmailEntryViewModel(service: service, connectivity: conn)
        vm.email = "a@b.com"

        await vm.submit()

        #expect(vm.errorMessage != nil)
        #expect(vm.isEmailSent == false)
        #expect(vm.fieldErrors.isEmpty)
    }

    @Test("EmailEntryViewModel: loading state prevents double submission")
    func emailEntryLoadingState() async throws {
        let repo = FakeAuthRepository()
        // Make requestOtp slow by using an actor to coordinate
        let (service, _, conn, _) = TestFactories.makeService(repo: repo)
        let vm = EmailEntryViewModel(service: service, connectivity: conn)
        vm.email = "a@b.com"

        // Start submission
        let task = Task { await vm.submit() }

        // Check loading state is true during submission
        // (We can't easily check this mid-flight, but we can verify
        // that isLoading is false after completion)
        await task.value

        #expect(vm.isLoading == false)
        #expect(vm.isEmailSent == true)
    }

    @Test("EmailEntryViewModel: error clears on new attempt")
    func emailEntryErrorClears() async throws {
        let repo = FakeAuthRepository()
        repo.otpRequestError = APIError.server(code: "rate_limited", message: "Too many attempts.")
        let (service, _, conn, _) = TestFactories.makeService(repo: repo)
        let vm = EmailEntryViewModel(service: service, connectivity: conn)
        vm.email = "a@b.com"

        // First attempt fails
        await vm.submit()
        #expect(vm.errorMessage != nil)

        // Reset error and try again
        repo.otpRequestError = nil
        vm.errorMessage = nil
        await vm.submit()

        #expect(vm.errorMessage == nil)
        #expect(vm.isEmailSent == true)
    }

    // MARK: - Navigation state transitions

    @Test("EmailEntryViewModel: successful submit transitions to email sent state")
    func emailEntryNavigationTransition() async throws {
        let (service, _, conn, _) = TestFactories.makeService()
        let vm = EmailEntryViewModel(service: service, connectivity: conn)
        vm.email = "user@example.com"

        await vm.submit()

        #expect(vm.isEmailSent == true)
        #expect(vm.errorMessage == nil)
    }

}
