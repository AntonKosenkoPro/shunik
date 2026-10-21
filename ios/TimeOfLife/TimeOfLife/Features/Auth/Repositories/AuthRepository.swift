import Foundation

/// Protocol for the auth data source. Production uses `RemoteAuthRepository`
/// over `APIClient`; tests use `FakeAuthRepository` to drive view models and
/// `AuthService` without a network.
protocol AuthRepository: Sendable {
    /// `POST /auth/otp/request` — always 202 (no enumeration). The server
    /// upserts a user and emails a 6-digit code.
    func requestOtp(email: String) async throws
    /// `POST /auth/otp/verify` — returns tokens + user on success.
    func verifyOtp(email: String, code: String) async throws -> AuthSession
    /// `POST /auth/apple` — exchanges Apple's identity token for a session.
    func appleSignIn(identityToken: String) async throws -> AuthSession
    /// `POST /auth/refresh` — rotates tokens. `attemptId` is always sent: the
    /// backend binds it to the presented predecessor for response-loss
    /// recovery (repeating the same predecessor + attempt reclaims a
    /// committed-but-undelivered rotation instead of tripping reuse).
    func refresh(refreshToken: String, attemptId: String) async throws -> AuthSession
    /// `POST /auth/logout` (Bearer) — 204.
    func logout() async throws
    /// `GET /auth/me` (Bearer).
    func me() async throws -> UserDTO
}
