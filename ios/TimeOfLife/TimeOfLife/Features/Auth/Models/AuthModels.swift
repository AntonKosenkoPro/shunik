import Foundation

/// A signed-in user as returned by the API (verify, me).
struct UserDTO: Codable, Equatable, Sendable {
    let id: String
    let email: String
    let emailVerified: Bool
    /// Whether this account has an Apple identity attached. Account metadata
    /// only — it is NOT the current session's authentication method (an
    /// Apple-linked account may hold an email-OTP session). The client must
    /// never infer the provider from the email suffix.
    let hasAppleIdentity: Bool?
    /// True when an Apple-created account has no stored revocable credential:
    /// explicit deletion must first obtain fresh same-subject Apple
    /// authorization via `POST /auth/apple/deletion-credential` (never
    /// silently skip automatic revocation).
    let appleDeletionAuthorizationRequired: Bool?

    enum CodingKeys: String, CodingKey {
        case id, email
        case emailVerified = "email_verified"
        case hasAppleIdentity = "has_apple_identity"
        case appleDeletionAuthorizationRequired = "apple_deletion_authorization_required"
    }

    init(
        id: String,
        email: String,
        emailVerified: Bool,
        hasAppleIdentity: Bool? = nil,
        appleDeletionAuthorizationRequired: Bool? = nil
    ) {
        self.id = id
        self.email = email
        self.emailVerified = emailVerified
        self.hasAppleIdentity = hasAppleIdentity
        self.appleDeletionAuthorizationRequired = appleDeletionAuthorizationRequired
    }
}

/// Response body for `/auth/otp/verify` and `/auth/refresh`: tokens + user.
struct AuthSession: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let user: UserDTO
    /// Expiring account-status credential (30-day, dedicated signing key and
    /// purpose). Stored separately from the login snapshot — its only power
    /// is checking whether the original account UUID still exists. Optional:
    /// older relays omit it and old clients proceed with lock-not-wipe.
    let accountStatusCredential: String?
    /// RFC 3339 expiry of `accountStatusCredential`. The client stops other-
    /// device status checks at expiry (never relaxes the check) and preserves
    /// files when evidence is expired or missing.
    let accountStatusExpiresAt: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case user
        case accountStatusCredential = "account_status_credential"
        case accountStatusExpiresAt = "account_status_expires_at"
    }

    init(
        accessToken: String,
        refreshToken: String,
        user: UserDTO,
        accountStatusCredential: String? = nil,
        accountStatusExpiresAt: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.user = user
        self.accountStatusCredential = accountStatusCredential
        self.accountStatusExpiresAt = accountStatusExpiresAt
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
/// `authorizationCode` is the single-use code exchanged server-side for a
/// revocable refresh token bound to the same Apple subject/audience.
/// Optional so identity-token-only clients from the rollout window keep
/// working; missing stored credentials are never treated as completed
/// automatic revocation.
struct AppleSignInRequest: Codable, Equatable, Sendable {
    let identityToken: String
    let authorizationCode: String?
    enum CodingKeys: String, CodingKey {
        case identityToken = "identity_token"
        case authorizationCode = "authorization_code"
    }

    init(identityToken: String, authorizationCode: String? = nil) {
        self.identityToken = identityToken
        self.authorizationCode = authorizationCode
    }
}

/// `POST /auth/apple/deletion-credential` body. Verifies the same Apple
/// subject for an existing Apple account lacking a stored revocable
/// credential and saves it before DELETE. Never creates a user or issues
/// another Lifio session; a different identity is rejected.
struct AppleDeletionCredentialRequest: Codable, Equatable, Sendable {
    let identityToken: String
    let authorizationCode: String?
    enum CodingKeys: String, CodingKey {
        case identityToken = "identity_token"
        case authorizationCode = "authorization_code"
    }
}

/// `GET /api/v1/auth/me` response: the user plus a fresh status credential.
/// The credential renews the 30-day other-device deletion evidence while
/// authenticated; replaying no request renews it (status requests never do).
struct MeResponse: Codable, Equatable, Sendable {
    let user: UserDTO
    let accountStatusCredential: String?
    let accountStatusExpiresAt: String?

    enum CodingKeys: String, CodingKey {
        case user
        case accountStatusCredential = "account_status_credential"
        case accountStatusExpiresAt = "account_status_expires_at"
    }

    init(user: UserDTO, accountStatusCredential: String? = nil, accountStatusExpiresAt: String? = nil) {
        self.user = user
        self.accountStatusCredential = accountStatusCredential
        self.accountStatusExpiresAt = accountStatusExpiresAt
    }
}

/// `DELETE /api/v1/auth/account` 202 body. Sent only after the operational
/// purge and durable Apple-revocation work commit together. `accountDeleted`
/// confirms the account is gone; `appleRevocationPending` distinguishes
/// durable pending automatic revocation from completion (204 = purge plus
/// revocation complete or not applicable — email accounts need no Apple
/// work). Never claim 202 as completed Apple unlinking.
struct AccountDeletionResponse: Codable, Equatable, Sendable {
    let accountDeleted: Bool
    let appleRevocationPending: Bool

    enum CodingKeys: String, CodingKey {
        case accountDeleted = "account_deleted"
        case appleRevocationPending = "apple_revocation_pending"
    }
}

/// The client's interpretation of `DELETE /api/v1/auth/account`: 204 and
/// 202 are both reliable account-deletion acknowledgments with different
/// Apple-unlink meaning. Anything else (generic 401/404, malformed,
/// offline/5xx) is NOT deletion evidence.
enum AccountDeletionOutcome: Equatable, Sendable {
    /// Purge plus Apple revocation complete (or not applicable).
    case completed
    /// Purge committed; minimal encrypted Apple-revocation work remains
    /// durable with automatic retry.
    case pendingAppleRevocation
}

/// `POST /api/v1/auth/account/status` response: the verified credential
/// subject's account state. The client must match `accountID` against its
/// original intent/monitor UUID — a mismatched verdict preserves files.
struct AccountStatusResponse: Codable, Equatable, Sendable {
    let accountID: String
    let state: AccountLifecycleState

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case state
    }
}

/// Account lifecycle verdict scoped to one immutable account UUID.
enum AccountLifecycleState: String, Codable, Equatable, Sendable {
    case active
    case deleted
}
