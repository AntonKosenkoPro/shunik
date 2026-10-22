import Foundation
import Security

/// Production `KeychainStoring` backed by the Security framework.
///
/// Uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so secrets survive
/// first unlock but never leave the device (no iCloud sync). Concurrency:
/// Keychain Services is thread-safe; we wrap the calls in an actor so the
/// protocol is uniform with the in-memory test double.
actor KeychainStore: KeychainStoring {
    private let service: String

    init(service: String = "com.timeoflife.keychain") {
        self.service = service
    }

    func setString(_ string: String, for key: KeychainKey) async {
        let data = Data(string.utf8)
        var query: [String: Any] = baseQuery(for: key)
        // Delete before add to avoid duplicates (no sec_item_update needed).
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    func string(for key: KeychainKey) async -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func remove(key: KeychainKey) async {
        let query = baseQuery(for: key)
        SecItemDelete(query as CFDictionary)
    }

    /// Saves the snapshot with one status-checked write: update the existing
    /// item, or add it when absent. The existing item is never deleted first,
    /// so a failing write preserves the last usable snapshot.
    func saveSnapshot(_ snapshot: CredentialSnapshot) async -> Result<Void, KeychainError> {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return .failure(.storageUnavailable(underlying: "snapshot encode failed"))
        }
        let query = baseQuery(for: .credentialSnapshot)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            return .failure(.storageUnavailable(underlying: "save OSStatus \(status)"))
        }
        return .success(())
    }

    /// Loads the snapshot, distinguishing absence (`errSecItemNotFound` →
    /// `.success(nil)`) from temporary failures (any other `OSStatus` →
    /// `.failure`). A corrupt item is reported as unavailable, never as
    /// absent: callers must not wipe a session they cannot read.
    func loadSnapshot() async -> Result<CredentialSnapshot?, KeychainError> {
        var query = baseQuery(for: .credentialSnapshot)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                return .failure(.storageUnavailable(underlying: "snapshot data missing"))
            }
            do {
                return .success(try JSONDecoder().decode(CredentialSnapshot.self, from: data))
            } catch {
                // Decode detail is diagnostics-only: callers surface the
                // localized fallback, never this string. The description
                // names the schema mismatch, not secret bytes.
                return .failure(.storageUnavailable(underlying: "snapshot decode failed: \(error)"))
            }
        case errSecItemNotFound:
            return .success(nil)
        default:
            return .failure(.storageUnavailable(underlying: "load OSStatus \(status)"))
        }
    }

    func removeSnapshot() async {
        let query = baseQuery(for: .credentialSnapshot)
        SecItemDelete(query as CFDictionary)
    }

    /// Saves one JSON account-deletion artifact with the same status-checked
    /// discipline as the snapshot: update the existing item, or add it when
    /// absent. The existing item is never deleted first, so a failing write
    /// preserves the last usable value.
    func saveDeletionJSON(_ json: String, for key: KeychainKey) async -> Result<Void, KeychainError> {
        guard let data = json.data(using: .utf8) else {
            return .failure(.storageUnavailable(underlying: "deletion json encode failed"))
        }
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            return .failure(.storageUnavailable(underlying: "save OSStatus \(status)"))
        }
        return .success(())
    }

    /// Loads one JSON account-deletion artifact, distinguishing absence
    /// (`errSecItemNotFound` → `.success(nil)`) from temporary failures (any
    /// other `OSStatus` → `.failure`). A corrupt item is reported as
    /// unavailable, never as absent.
    func loadDeletionJSON(for key: KeychainKey) async -> Result<String?, KeychainError> {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let json = String(data: data, encoding: .utf8) else {
                return .failure(.storageUnavailable(underlying: "deletion json data missing"))
            }
            return .success(json)
        case errSecItemNotFound:
            return .success(nil)
        default:
            return .failure(.storageUnavailable(underlying: "load OSStatus \(status)"))
        }
    }

    func removeDeletionJSON(for key: KeychainKey) async {
        let query = baseQuery(for: key)
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(for key: KeychainKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}
