import Testing
import Foundation
@testable import Shunik

@MainActor
@Suite("WelcomeViewModel — Sign in with Apple")
struct WelcomeViewModelTests {

    private func makeService(
        repo: FakeAuthRepository = FakeAuthRepository()
    ) -> (AuthService, FakeAuthRepository, Connectivity, SessionStore) {
        let keychain = InMemoryKeychainStore()
        let cache = SessionCache(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SessionStore()
        let service = AuthService(
            repository: repo,
            keychain: keychain,
            cache: cache,
            sessionStore: store
        )
        return (service, repo, Connectivity(), store)
    }

    private func makeWelcomeVM(
        service: AuthService,
        provider: FakeAppleAuthorizationProvider = FakeAppleAuthorizationProvider()
    ) -> (WelcomeViewModel, FakeAppleAuthorizationProvider) {
        let appleService = AppleSignInService(provider: provider)
        let vm = WelcomeViewModel(service: service, appleService: appleService)
        return (vm, provider)
    }

    @Test("Apple sign-in success exchanges token and signs in")
    func appleSignInSuccess() async throws {
        let (service, repo, _, store) = makeService()
        let (vm, _) = makeWelcomeVM(service: service)

        await vm.signInWithApple()

        #expect(repo.calls == [.appleSignIn(identityToken: "id-token", authorizationCode: nil)])
        #expect(vm.errorMessage == nil)
        #expect(vm.isLoading == false)
        if case .signedIn(let session) = store.state {
            #expect(session.email == "apple@privaterelay.appleid.com")
        } else {
            Issue.record("expected signed-in state after Apple sign-in")
        }
    }

    @Test("Apple sign-in delegates to backend; offline is handled by the view")
    func appleSignInOfflineHandledByView() async throws {
        let (service, repo, _, _) = makeService()
        let (vm, _) = makeWelcomeVM(service: service)

        await vm.signInWithApple()

        // The view disables the Apple button when offline, so the VM no longer
        // guards connectivity itself and should proceed with the backend call.
        #expect(repo.calls == [.appleSignIn(identityToken: "id-token", authorizationCode: nil)])
        #expect(vm.errorMessage == nil)
    }

    @Test("Apple sign-in canceled is silent")
    func appleSignInCanceled() async throws {
        let (service, repo, _, _) = makeService()
        let provider = FakeAppleAuthorizationProvider()
        provider.error = AppleSignInError.canceled
        let (vm, _) = makeWelcomeVM(service: service, provider: provider)

        await vm.signInWithApple()

        #expect(repo.calls.isEmpty)
        #expect(vm.errorMessage == nil)
    }

    @Test("Apple provider failure shows apple error")
    func appleSignInProviderFailed() async throws {
        let (service, repo, _, _) = makeService()
        let provider = FakeAppleAuthorizationProvider()
        provider.error = AppleSignInError.failed("boom")
        let (vm, _) = makeWelcomeVM(service: service, provider: provider)

        await vm.signInWithApple()

        #expect(repo.calls.isEmpty)
        #expect(vm.errorMessage != nil)
    }

    @Test("Apple backend error shows API error message")
    func appleSignInBackendError() async throws {
        let repo = FakeAuthRepository()
        repo.appleSignInError = APIError.server(code: "invalid_apple_token", message: "Invalid Apple identity token")
        let (service, _, _, _) = makeService(repo: repo)
        let (vm, _) = makeWelcomeVM(service: service)

        await vm.signInWithApple()

        #expect(vm.errorMessage != nil)
    }
}
