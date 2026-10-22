import Foundation

/// Abstract persistent secret storage (Keychain in production, in-memory
/// in tests). Only tokens live here — the session cache (id/email) is kept
/// in `UserDefaults` via `SessionCache`.
protocol KeychainStoring: AnyObject, Sendable {
    func setString(_ string: String, for key: KeychainKey) async
    func string(for key: KeychainKey) async -> String?
    func remove(key: KeychainKey) async
    /// Persists one complete credential snapshot (single Keychain item, one
    /// status-checked write — never split access-then-refresh writes).
    func saveSnapshot(_ snapshot: CredentialSnapshot) async -> Result<Void, KeychainError>
    /// Loads the durable snapshot. `.success(nil)` means no session;
    /// `.failure` means storage is temporarily unreadable — callers must
    /// keep retry intent instead of treating it as signed-out.
    func loadSnapshot() async -> Result<CredentialSnapshot?, KeychainError>
    /// Best-effort removal (sign-out / confirmed revocation).
    func removeSnapshot() async
    /// Persists one JSON-encoded account-deletion artifact (status-credential
    /// map, pending intent, or cleanup markers) with one status-checked
    /// write. A failing write preserves the last usable value.
    func saveDeletionJSON(_ json: String, for key: KeychainKey) async -> Result<Void, KeychainError>
    /// Loads one JSON-encoded account-deletion artifact. `.success(nil)`
    /// means absent; `.failure` means storage is temporarily unreadable —
    /// callers must distinguish the two (absent = nothing scheduled,
    /// unavailable = keep retry intent, never wipe).
    func loadDeletionJSON(for key: KeychainKey) async -> Result<String?, KeychainError>
    /// Best-effort removal of one account-deletion artifact (explicit
    /// sign-out/local erase or completed confirmed cleanup).
    func removeDeletionJSON(for key: KeychainKey) async
}

/// Stable Keychain keys. Never put user-facing data here — secrets only.
enum KeychainKey: String, Sendable {
    /// The single credential-snapshot item (JSON-encoded `CredentialSnapshot`).
    case credentialSnapshot = "com.timeoflife.credential_snapshot"
    /// Stable per-device identifier sent as `X-Device-Id` (device-sessions
    /// spec). Not a secret, but it must survive reinstalls like one.
    case deviceId = "com.timeoflife.device_id"
    /// Native Apple user identifier (`ASAuthorizationAppleIDCredential.user`)
    /// for the current Apple-authenticated session. Stored separately from
    /// the Lifio account UUID: `getCredentialState(forUserID:)` requires the
    /// native Apple user, never the Lifio UUID. Cleared on sign-out; absent
    /// means the current session is not Apple-authenticated on this device.
    case appleUserId = "com.timeoflife.apple_user_id"
    /// Account-keyed status credentials (JSON-encoded
    /// `[accountID: StoredStatusCredential]`). Never a login/refresh
    /// snapshot: its only power is the read-only account-status check.
    case accountStatusCredentials = "com.timeoflife.account_status_credentials"
    /// Pending deletion intent (JSON-encoded `AccountDeletionIntent?`).
    /// Persisted BEFORE the DELETE send so an ambiguous outcome stays
    /// recoverable across restart.
    case accountDeletionIntent = "com.timeoflife.account_deletion_intent"
    /// Durable cleanup markers (JSON-encoded `[accountID]`). Confirmed
    /// cleanup scheduled before auth artifacts are cleared; removed only
    /// after the exact UUID's local cleanup succeeds.
    case accountCleanupMarkers = "com.timeoflife.account_cleanup_markers"
}

/// One durable credential snapshot: the complete token pair plus the pending
/// refresh-attempt intent, bound to account + device + predecessor. Written
/// and replaced atomically — restart observes either the predecessor with
/// its pending attempt or the complete successor, never a mixed pair.
struct CredentialSnapshot: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    /// The `user.id` the tokens were issued for (account binding).
    var accountId: String
    /// The `X-Device-Id` the tokens were issued for (device binding).
    var deviceId: String?
    /// The in-flight logical rotation, if any. Persisted BEFORE the first
    /// network send and reused across suspension/restart until a complete
    /// successor snapshot is durably saved.
    var pendingAttemptId: String?
    /// The refresh token the pending attempt was minted for. Recovery reuses
    /// the attempt only while the durable predecessor still matches.
    var pendingPredecessor: String?
}

/// Keychain failures. Only temporary storage errors exist here: absence is
/// expressed as `.success(nil)` from `loadSnapshot`, never as an error.
enum KeychainError: Error, Equatable, Sendable {
    /// The item could not be read/written right now (e.g. a failing
    /// `OSStatus`). The last usable snapshot is preserved; callers keep
    /// retry intent and must NOT sign out on this.
    case storageUnavailable(underlying: String)
}

extension KeychainError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .storageUnavailable(underlying):
            return "keychain storage unavailable: \(underlying)"
        }
    }
}
