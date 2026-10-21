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
}

/// Stable Keychain keys. Never put user-facing data here — secrets only.
enum KeychainKey: String, Sendable {
    /// The single credential-snapshot item (JSON-encoded `CredentialSnapshot`).
    case credentialSnapshot = "com.timeoflife.credential_snapshot"
    /// Stable per-device identifier sent as `X-Device-Id` (device-sessions
    /// spec). Not a secret, but it must survive reinstalls like one.
    case deviceId = "com.timeoflife.device_id"
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
