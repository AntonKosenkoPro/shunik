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
    /// `POST /auth/apple` — exchanges Apple's identity for a session.
    /// `authorizationCode` (single-use, UTF-8 from Apple's Data proof) lets
    /// the server retain a revocable credential bound to the same Apple
    /// subject/audience; nil keeps identity-token-only rollout compatibility.
    func appleSignIn(identityToken: String, authorizationCode: String?) async throws -> AuthSession
    /// `POST /auth/refresh` — rotates tokens. `attemptId` is always sent: the
    /// backend binds it to the presented predecessor for response-loss
    /// recovery (repeating the same predecessor + attempt reclaims a
    /// committed-but-undelivered rotation instead of tripping reuse).
    func refresh(refreshToken: String, attemptId: String) async throws -> AuthSession
    /// `POST /auth/logout` (Bearer) — 204.
    func logout() async throws
    /// `GET /auth/me` (Bearer) — user plus a fresh status credential.
    func me() async throws -> MeResponse
    /// `DELETE /api/v1/auth/account` (Bearer + device ID) — deletes the
    /// authenticated account itself, never an arbitrary requested user.
    /// 204 = purge complete (Apple revocation complete or N/A);
    /// 202 (`account_deleted: true`) = purge committed with durable pending
    /// automatic Apple revocation. Both are deletion acknowledgments; 202
    /// must not be described as completed Apple unlinking. Anything else
    /// (generic 401/404, malformed, offline/5xx) is NOT deletion evidence
    /// and throws instead of returning an outcome.
    func deleteAccount() async throws -> AccountDeletionOutcome
    /// `POST /api/v1/auth/account/status` — read-only existence check for
    /// the credential's own account UUID, authenticated by the dedicated
    /// status capability (never the session token, never refreshed). Callers
    /// must match the returned UUID against their intent/monitor UUID.
    func fetchAccountStatus(statusCredential: String) async throws -> AccountStatusResponse
    /// `POST /api/v1/auth/apple/deletion-credential` (Bearer) — verifies the
    /// same Apple subject for an existing Apple account lacking a stored
    /// revocable credential and saves it before DELETE. Never creates a user
    /// or issues another session; a different identity is rejected.
    func acquireAppleDeletionCredential(identityToken: String, authorizationCode: String?) async throws
}
