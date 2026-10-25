import Foundation

/// Stable per-device identifier (device-sessions spec). Mints a UUID on
/// first need, persists it in the Keychain, and reuses it on every
/// subsequent request. The identifier is sent as `X-Device-Id` on the
/// session-carrying auth routes (verify, Apple sign-in, refresh, logout)
/// and scopes refresh-token families, reuse detection, and logout to a
/// single device.
///
/// Restore-on-new-phone: no model/name fingerprint comparison is performed.
/// `KeychainStore` persists items with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which never travels
/// in device backups or device-to-device migrations — a new phone has no
/// stored identifier and mints a fresh one on first sign-in, which is
/// exactly the spec's re-mint behavior without an unreliable fingerprint
/// (a same-model replacement restored from backup would carry an identical
/// fingerprint and could rotate refresh families needlessly). Reuse of the
/// identifier on same-device reinstall is by design. Device enumeration and
/// any server-side device accounting remain out of scope here (issue #46).
actor DeviceIdentityStore {
    private let keychain: KeychainStoring
    private var cached: String?

    init(keychain: KeychainStoring) {
        self.keychain = keychain
    }

    /// Returns the stable device identifier, minting and persisting a new
    /// UUID the first time (or after a Keychain restore that carried nothing).
    func current() async -> String {
        if let cached, !cached.isEmpty { return cached }
        if let stored = await keychain.string(for: .deviceId), !stored.isEmpty {
            cached = stored
            return stored
        }
        let minted = UUID().uuidString
        await keychain.setString(minted, for: .deviceId)
        cached = minted
        return minted
    }
}
