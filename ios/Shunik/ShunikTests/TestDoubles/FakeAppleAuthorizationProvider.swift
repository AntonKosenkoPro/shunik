import Foundation
@testable import Shunik

/// Test double for `AppleAuthorizationProviding`. Returns a canned credential
/// or throws a configured error, so the Apple flow is exercisable without the
/// Sign in with Apple capability.
@MainActor
final class FakeAppleAuthorizationProvider: AppleAuthorizationProviding {
    var credential: AppleCredential?
    var error: Error?

    func performAppleIDRequest() async throws -> AppleCredential {
        if let error { throw error }
        return credential ?? AppleCredential(
            identityToken: "id-token",
            user: "apple-sub-1",
            email: "apple@privaterelay.appleid.com"
        )
    }
}
