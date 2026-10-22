import Foundation

/// Durable account-deletion artifacts in the Keychain (account-deletion
/// spec): the account-keyed status-credential map, the pending deletion
/// intent, and the cleanup markers. All three live in SEPARATE Keychain items
/// from the login/refresh snapshot — a status credential is never a second
/// cached session and can never unlock anything.
///
/// Absent (`.success(nil)` / empty) means nothing is scheduled; `.failure`
/// means storage is temporarily unreadable — callers must keep retry intent
/// and NEVER wipe. Codable shapes are edited in place (pre-release: no
/// legacy branches).
struct AccountDeletionStorage: Sendable {
    private let keychain: KeychainStoring

    init(keychain: KeychainStoring) {
        self.keychain = keychain
    }

    // MARK: - Status credentials

    /// Returns the stored status credential for one account, or nil when none
    /// was ever saved for it. A stored credential with a missing, unparsable,
    /// or past RFC 3339 expiry is returned as nil: expired/missing evidence
    /// preserves files and never authorizes cleanup.
    func loadStatusCredential(accountID: String) async -> Result<StoredStatusCredential?, KeychainError> {
        switch await keychain.loadDeletionJSON(for: .accountStatusCredentials) {
        case .failure(let error):
            return .failure(error)
        case .success(nil):
            return .success(nil)
        case .success(let json?):
            guard let data = json.data(using: .utf8),
                  let map = try? JSONDecoder().decode([String: StoredStatusCredential].self, from: data) else {
                return .failure(.storageUnavailable(underlying: "status credential decode failed"))
            }
            let stored = map[accountID]
            guard let stored, Self.isUsable(stored) else { return .success(nil) }
            return .success(stored)
        }
    }

    /// Saves (or replaces) one account's status credential. Never touches
    /// other accounts' entries in the map.
    func saveStatusCredential(_ credential: String, expiresAt: String?, accountID: String) async -> Result<Void, KeychainError> {
        var map = [String: StoredStatusCredential]()
        switch await keychain.loadDeletionJSON(for: .accountStatusCredentials) {
        case .failure(let error):
            return .failure(error)
        case .success(nil):
            break
        case .success(let json?):
            guard let data = json.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: StoredStatusCredential].self, from: data) else {
                return .failure(.storageUnavailable(underlying: "status credential decode failed"))
            }
            map = decoded
        }
        map[accountID] = StoredStatusCredential(credential: credential, expiresAt: expiresAt)
        guard let data = try? JSONEncoder().encode(map),
              let json = String(data: data, encoding: .utf8) else {
            return .failure(.storageUnavailable(underlying: "status credential encode failed"))
        }
        return await keychain.saveDeletionJSON(json, for: .accountStatusCredentials)
    }

    /// Removes one account's status credential (explicit sign-out/local erase
    /// or completed confirmed cleanup). Best-effort.
    func removeStatusCredential(accountID: String) async {
        guard case .success(let json) = await keychain.loadDeletionJSON(for: .accountStatusCredentials),
              let json,
              let data = json.data(using: .utf8),
              var map = try? JSONDecoder().decode([String: StoredStatusCredential].self, from: data) else {
            return
        }
        map.removeValue(forKey: accountID)
        guard let encoded = try? JSONEncoder().encode(map),
              let out = String(data: encoded, encoding: .utf8) else { return }
        _ = await keychain.saveDeletionJSON(out, for: .accountStatusCredentials)
    }

    // MARK: - Pending intent

    /// The durable deletion intent, persisted BEFORE the DELETE send.
    func loadIntent() async -> Result<AccountDeletionIntent?, KeychainError> {
        switch await keychain.loadDeletionJSON(for: .accountDeletionIntent) {
        case .failure(let error):
            return .failure(error)
        case .success(nil):
            return .success(nil)
        case .success(let json?):
            guard let data = json.data(using: .utf8),
                  let intent = try? JSONDecoder().decode(AccountDeletionIntent.self, from: data) else {
                return .failure(.storageUnavailable(underlying: "deletion intent decode failed"))
            }
            return .success(intent)
        }
    }

    func saveIntent(_ intent: AccountDeletionIntent) async -> Result<Void, KeychainError> {
        guard let data = try? JSONEncoder().encode(intent),
              let json = String(data: data, encoding: .utf8) else {
            return .failure(.storageUnavailable(underlying: "deletion intent encode failed"))
        }
        return await keychain.saveDeletionJSON(json, for: .accountDeletionIntent)
    }

    func clearIntent() async {
        await keychain.removeDeletionJSON(for: .accountDeletionIntent)
    }

    // MARK: - Cleanup markers

    /// Account IDs with confirmed deletion whose local cleanup is scheduled
    /// (or in progress). Removed only after that exact UUID's cleanup
    /// succeeds — never when another account is active.
    func loadCleanupMarkers() async -> Result<[String], KeychainError> {
        switch await keychain.loadDeletionJSON(for: .accountCleanupMarkers) {
        case .failure(let error):
            return .failure(error)
        case .success(nil):
            return .success([])
        case .success(let json?):
            guard let data = json.data(using: .utf8),
                  let markers = try? JSONDecoder().decode([String].self, from: data) else {
                return .failure(.storageUnavailable(underlying: "cleanup markers decode failed"))
            }
            return .success(markers)
        }
    }

    func addCleanupMarker(accountID: String) async -> Result<Void, KeychainError> {
        switch await loadCleanupMarkers() {
        case .failure(let error):
            return .failure(error)
        case .success(var markers):
            if !markers.contains(accountID) { markers.append(accountID) }
            guard let data = try? JSONEncoder().encode(markers),
                  let json = String(data: data, encoding: .utf8) else {
                return .failure(.storageUnavailable(underlying: "cleanup markers encode failed"))
            }
            return await keychain.saveDeletionJSON(json, for: .accountCleanupMarkers)
        }
    }

    func removeCleanupMarker(accountID: String) async {
        guard case .success(var markers) = await loadCleanupMarkers() else { return }
        markers.removeAll { $0 == accountID }
        guard let data = try? JSONEncoder().encode(markers),
              let json = String(data: data, encoding: .utf8) else { return }
        _ = await keychain.saveDeletionJSON(json, for: .accountCleanupMarkers)
    }

    // MARK: - Expiry

    /// A stored credential is usable only with a parsable RFC 3339 expiry in
    /// the future. Missing/unparsable/expired evidence preserves files.
    static func isUsable(_ stored: StoredStatusCredential, now: Date = Date()) -> Bool {
        guard let expiresAt = stored.expiresAt, !stored.credential.isEmpty else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: expiresAt) { return now < date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = plain.date(from: expiresAt) else { return false }
        return now < date
    }
}

/// One account's status credential with its RFC 3339 expiry.
struct StoredStatusCredential: Codable, Equatable, Sendable {
    let credential: String
    let expiresAt: String?
}

/// Durable deletion intent for one account, written BEFORE the DELETE send so
/// an ambiguous outcome (lost response, restart) stays recoverable without
/// claiming success or erasing on assumption.
struct AccountDeletionIntent: Codable, Equatable, Sendable {
    /// The immutable account UUID the DELETE targeted.
    let accountID: String
    /// The status credential stored before DELETE for ambiguous-outcome
    /// resolution. Retained on generic lock; cleared on explicit sign-out,
    /// local erase, or completed cleanup.
    let statusCredential: String
    /// Where the lifecycle stands: intent persisted (DELETE not yet
    /// acknowledged) or cleanup durably scheduled (deletion confirmed).
    let phase: AccountDeletionPhase
    let createdAt: Date
}

/// Lifecycle phase of a pending deletion intent.
enum AccountDeletionPhase: String, Codable, Equatable, Sendable {
    /// Intent persisted; DELETE sent or send outcome unknown. Sync for the
    /// account stays fenced until a scoped verdict or explicit cancel.
    case intentPending = "intent_pending"
    /// Deletion confirmed (204/202 or scoped `deleted` verdict); local
    /// cleanup of the exact UUID is scheduled and survives restart.
    case cleanupRequired = "cleanup_required"
}
