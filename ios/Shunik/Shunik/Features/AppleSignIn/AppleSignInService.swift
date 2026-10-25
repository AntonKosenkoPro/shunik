import AuthenticationServices
import Foundation
import UIKit

/// Errors surfaced by the Apple sign-in flow.
enum AppleSignInError: Error, Equatable {
    case canceled
    case missingIdentityToken
    case failed(String)

    static func == (lhs: AppleSignInError, rhs: AppleSignInError) -> Bool {
        switch (lhs, rhs) {
        case (.canceled, .canceled),
             (.missingIdentityToken, .missingIdentityToken):
            return true
        case let (.failed(a), .failed(b)):
            return a == b
        default:
            return false
        }
    }
}

/// The Apple credential material we forward to the backend. Only `identityToken`
/// (and `authorizationCode` when present) is sent — `/auth/apple` on sign-in,
/// `/auth/apple/deletion-credential` during explicit deletion for Apple
/// accounts lacking a stored revocable credential. `user` is Apple's stable
/// identifier (`sub`): it is preserved separately from the Shunik account UUID
/// because `getCredentialState(forUserID:)` requires the native Apple user,
/// never the Shunik UUID. `email` is kept for future use (Apple delivers
/// `email`/`fullName` only on the first authorization, so it is optional).
/// `authorizationCode` is Apple's single-use Data proof, UTF-8 decoded like
/// the identity token; the server exchanges it for a revocable credential
/// bound to the same Apple subject/audience. Official docs: AuthenticationServices
/// `ASAuthorizationAppleIDCredential` (identityToken, authorizationCode, user),
/// `ASAuthorizationAppleIDProvider.credentialState(forUserID:)` (async, iOS 13+),
/// `credentialRevokedNotification`, `ASAuthorizationError.Code.canceled`
/// (developer.apple.com/tutorials/data/documentation/authenticationservices/,
/// pin iOS 18 SDK via Xcode 16+; Account.md/INTERACTIONS.md carry the full list).
struct AppleCredential: Sendable, Equatable {
    /// The Apple identity-token JWT (RS256), UTF-8 decoded from `Data`.
    let identityToken: String
    /// Apple's stable user identifier (`sub`). Equals the JWT `sub` claim.
    /// Required for native credential-state observation — never the Shunik UUID.
    let user: String
    /// The user's email (real or `*@privaterelay.appleid.com`). First auth only.
    let email: String?
    /// Apple's single-use authorization code, UTF-8 decoded from `Data`.
    /// Short-lived proof the server exchanges for a revocable credential.
    /// Nil when Apple omits it (older flows) or in tests that predate it.
    let authorizationCode: String?

    init(identityToken: String, user: String, email: String? = nil, authorizationCode: String? = nil) {
        self.identityToken = identityToken
        self.user = user
        self.email = email
        self.authorizationCode = authorizationCode
    }
}

/// Indirection over `ASAuthorizationAppleIDProvider` so the flow is testable
/// without the Sign in with Apple capability / a device.
@MainActor
protocol AppleAuthorizationProviding {
    /// Performs the Apple ID authorization request and returns the credential.
    func performAppleIDRequest() async throws -> AppleCredential
}

/// Real provider-backed authorization (`@MainActor` for the delegate callbacks; held by the service for the request).
@MainActor
final class AppleIDAuthorizationProvider: NSObject, AppleAuthorizationProviding {
    private var continuation: CheckedContinuation<AppleCredential, Error>?

    func performAppleIDRequest() async throws -> AppleCredential {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private func resume(_ result: Result<AppleCredential, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case let .success(cred): continuation.resume(returning: cred)
        case let .failure(err): continuation.resume(throwing: err)
        }
    }
}

extension AppleIDAuthorizationProvider: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8)
        else {
            resume(.failure(AppleSignInError.missingIdentityToken))
            return
        }
        // The authorization code is a separate short-lived Data proof
        // (official docs: `authorizationCode` on `ASAuthorizationAppleIDCredential`,
        // UTF-8 decoded like the identity token). It may be absent on older
        // flows — the backend keeps identity-token-only compatibility then.
        let code: String?
        if let codeData = cred.authorizationCode {
            let decoded = String(data: codeData, encoding: .utf8)
            code = (decoded?.isEmpty == false) ? decoded : nil
        } else {
            code = nil
        }
        resume(.success(AppleCredential(identityToken: token, user: cred.user, email: cred.email, authorizationCode: code)))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        if let asError = error as? ASAuthorizationError, asError.code == .canceled {
            resume(.failure(AppleSignInError.canceled))
        } else {
            resume(.failure(AppleSignInError.failed(error.localizedDescription)))
        }
    }
}

extension AppleIDAuthorizationProvider: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first
        else {
            return ASPresentationAnchor()
        }
        return window
    }
}

/// Orchestrates the Apple sign-in flow. Wraps an injectable
/// `AppleAuthorizationProviding` so the success/canceled/failed paths are
/// unit-testable without the Apple capability.
@MainActor
final class AppleSignInService {
    private let provider: AppleAuthorizationProviding

    init(provider: AppleAuthorizationProviding = AppleIDAuthorizationProvider()) {
        self.provider = provider
    }

    /// Runs the Apple authorization request and returns the credential.
    func signIn() async throws -> AppleCredential {
        try await provider.performAppleIDRequest()
    }
}
