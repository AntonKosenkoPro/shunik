import Testing
import Foundation
@testable import Shunik

@MainActor
@Suite("AppleSignInService")
struct AppleSignInServiceTests {

    @Test("signIn returns the provider credential")
    func returnsCredential() async throws {
        let provider = FakeAppleAuthorizationProvider()
        let cred = AppleCredential(identityToken: "tok", user: "u", email: "e@x.com")
        provider.credential = cred

        let service = AppleSignInService(provider: provider)
        let result = try await service.signIn()

        #expect(result == cred)
    }

    @Test("signIn propagates canceled")
    func propagatesCanceled() async throws {
        let provider = FakeAppleAuthorizationProvider()
        provider.error = AppleSignInError.canceled

        let service = AppleSignInService(provider: provider)
        do {
            _ = try await service.signIn()
            Issue.record("expected AppleSignInError.canceled")
        } catch AppleSignInError.canceled {
            // ok
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("signIn propagates failed")
    func propagatesFailed() async throws {
        let provider = FakeAppleAuthorizationProvider()
        provider.error = AppleSignInError.failed("boom")

        let service = AppleSignInService(provider: provider)
        do {
            _ = try await service.signIn()
            Issue.record("expected AppleSignInError.failed")
        } catch let AppleSignInError.failed(msg) {
            #expect(msg == "boom")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
