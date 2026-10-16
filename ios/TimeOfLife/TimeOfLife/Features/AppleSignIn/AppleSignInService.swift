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
/// is sent to `/auth/apple`; `user` and `email` are kept for future use (e.g.
/// credential-state checks). Apple delivers `email`/`fullName` only on the
/// first authorization, so `email` is optional.
struct AppleCredential: Sendable, Equatable {
    /// The Apple identity-token JWT (RS256), UTF-8 decoded from `Data`.
    let identityToken: String
    /// Apple's stable user identifier (`sub`). Equals the JWT `sub` claim.
    let user: String
    /// The user's email (real or `*@privaterelay.appleid.com`). First auth only.
    let email: String?
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
        resume(.success(AppleCredential(identityToken: token, user: cred.user, email: cred.email)))
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
