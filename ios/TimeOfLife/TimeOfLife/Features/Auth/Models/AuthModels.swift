import Foundation

/// A signed-in user as returned by the API (verify, me).
struct UserDTO: Codable, Equatable, Sendable {
    let id: String
    let email: String
    let emailVerified: Bool

    enum CodingKeys: String, CodingKey {
        case id, email
        case emailVerified = "email_verified"
    }
}

/// Response body for `/auth/otp/verify` and `/auth/refresh`: tokens + user.
struct AuthSession: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let user: UserDTO

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case user
    }
}

/// Request bodies — keep them tiny and explicit so tests can assert payloads.

/// `POST /auth/otp/request` body.
struct OtpRequestRequest: Codable, Equatable, Sendable {
    let email: String
}

/// `POST /auth/otp/verify` body.
struct OtpVerifyRequest: Codable, Equatable, Sendable {
    let email: String
    let code: String
}

/// `POST /auth/refresh` body. `refreshAttemptId` is always sent (updated
/// clients): the backend binds it to one predecessor for response-loss
/// recovery, and treats a missing field as a legacy non-recoverable rotation.
struct RefreshRequest: Codable, Equatable, Sendable {
    let refreshToken: String
    let refreshAttemptId: String
    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
        case refreshAttemptId = "refresh_attempt_id"
    }
}

/// `POST /auth/apple` body. `identityToken` is Apple's RS256 identity-token JWT.
struct AppleSignInRequest: Codable, Equatable, Sendable {
    let identityToken: String
    enum CodingKeys: String, CodingKey { case identityToken = "identity_token" }
}
