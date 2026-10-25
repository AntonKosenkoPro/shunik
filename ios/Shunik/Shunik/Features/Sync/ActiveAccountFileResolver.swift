import Foundation

/// Resolves the ACTIVE household's database file for extension surfaces —
/// no session of their own, so the shared-session household id selects the file.
///
/// The household id is read FILE-FIRST (`active-session-household-id` in the
/// container, mirrored by `HouseholdService` on every successful resolve)
/// with the shared `com.shunik.session.householdID` defaults key as fallback:
/// suite `UserDefaults` reads detach from `cfprefsd` inside some extension
/// processes (observed on-device: intent silently resolved `.locked` for a
/// real session), while group-container file reads stay reliable.
///
/// Resolution rules:
/// - No shared household id (signed out at the auth gate, or never resolved
///   online with no cached household) → `.locked`: the control shows a
///   locked/empty state and never reads or creates an anonymous file.
/// - A household id exists but its file is missing on disk → `.noData`:
///   the control shows an empty state without creating the file.
/// - A readable file → `.ready` with its URL; the caller opens it read-only
///   (or via the app's store when in-process) — never a dormant household's
///   file, because only the active household id is ever resolved.
///
/// Never opens, migrates, or writes a database file: extension surfaces must
/// not create files as a side effect of rendering (`LocalStore` remains the
/// single mutation chokepoint).
struct ActiveAccountFileResolver {
    /// Reads the shared household id from the app's defaults (production) —
    /// the same store `HouseholdService` writes.
    private let sessionDefaults: UserDefaults?

    init(sessionDefaults: UserDefaults? = nil) {
        self.sessionDefaults = sessionDefaults
    }

    /// The control-surface resolution outcomes.
    enum Resolution: Equatable {
        /// No active account (signed out): locked/empty state, no file touch.
        case locked
        /// An active account id exists but its file is absent (fresh or
        /// erased account, tracked only by the app): locked/empty state, no
        /// file created.
        case noData
        /// The active account's file exists and may be read.
        case ready(URL)
    }

    /// The `SessionCache` user-id key (SessionCache.swift: `Keys.id`) — kept
    /// in one place here rather than reaching into `SessionCache`'s private
    /// keys. Still used for the cross-process deletion marker.
    private static let sessionUserIDKey = "com.shunik.session.id"

    /// The session-id sidecar file in the container root (mirrored by
    /// `SessionCache` on sign-in, removed on sign-out). Still the deletion
    /// cleanup's cross-process marker.
    static let sessionFileName = "active-session-user-id"

    /// The sidecar URL for `SessionCache` wiring (nil when the shared
    /// container is unavailable — file mirroring stays off, defaults only).
    static func sessionFileURL() -> URL? {
        appGroupBase().appendingPathComponent(sessionFileName)
    }

    /// The household-session id key (written by `HouseholdService` on every
    /// successful resolve, cleared on sign-out).
    private static let sessionHouseholdIDKey = "com.shunik.session.householdID"

    /// The household-id sidecar file in the container root (mirrored by
    /// `HouseholdService` on resolve, removed on sign-out).
    static let householdSessionFileName = "active-session-household-id"

    /// The sidecar URL for `HouseholdService` wiring (nil when the shared
    /// container is unavailable — file mirroring stays off, defaults only).
    static func householdSessionFileURL() -> URL? {
        appGroupBase().appendingPathComponent(householdSessionFileName)
    }

    /// Reads the shared-session user id (file-first, defaults fallback)
    /// without resolving a file. Used by deletion cleanup to clear the
    /// cross-process marker ONLY when it still names the deleted UUID —
    /// never when another account is active.
    func readSessionUserID(base: URL? = nil) -> String? {
        readSessionFile(base: base) ?? readSessionDefaults()
    }

    /// Resolves the active household's file URL inside the App Group
    /// container (or `base` in tests/previews). Never creates anything.
    func resolve(base: URL? = nil) -> Resolution {
        let householdID = readHouseholdFile(base: base) ?? readHouseholdDefaults()
        guard let householdID, !householdID.isEmpty else {
            return .locked
        }
        let sanitized = householdID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !sanitized.isEmpty, sanitized == householdID else {
            return .locked
        }
        let container = base ?? Self.appGroupBase()
        let url = container.appendingPathComponent(
            LocalStore.databaseFileName(householdID: sanitized)
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .noData
        }
        return .ready(url)
    }

    /// The App Group shared container's UserDefaults (the shared session
    /// surface extensions read), or nil when the group is unavailable.
    private static func appGroupDefaults() -> UserDefaults? {
        UserDefaults(suiteName: LocalStore.appGroupID)
    }

    /// File-first session id (see type docs): nil when absent/unreadable.
    /// Read-only — never creates anything.
    private func readSessionFile(base: URL?) -> String? {
        readFile(named: Self.sessionFileName, base: base)
    }

    /// Suite-defaults session id (fallback for contexts where `cfprefsd`
    /// stays reachable).
    private func readSessionDefaults() -> String? {
        let defaults = sessionDefaults ?? Self.appGroupDefaults()
        guard let userID = defaults?.string(forKey: Self.sessionUserIDKey),
              !userID.isEmpty else {
            return nil
        }
        return userID
    }

    /// File-first household id (see type docs): nil when absent/unreadable.
    private func readHouseholdFile(base: URL?) -> String? {
        readFile(named: Self.householdSessionFileName, base: base)
    }

    /// Suite-defaults household id (fallback).
    private func readHouseholdDefaults() -> String? {
        let defaults = sessionDefaults ?? Self.appGroupDefaults()
        guard let householdID = defaults?.string(forKey: Self.sessionHouseholdIDKey),
              !householdID.isEmpty else {
            return nil
        }
        return householdID
    }

    /// Clears the household session (sidecar + defaults) — sign-out and
    /// account-deletion paths. The per-user cache is never touched here.
    func clearHouseholdSession(base: URL? = nil) {
        let container = base ?? Self.appGroupBase()
        try? FileManager.default.removeItem(
            at: container.appendingPathComponent(Self.householdSessionFileName)
        )
        let defaults = sessionDefaults ?? Self.appGroupDefaults()
        defaults?.removeObject(forKey: Self.sessionHouseholdIDKey)
    }

    /// Reads a sidecar file's trimmed contents, or nil when absent/unreadable.
    private func readFile(named fileName: String, base: URL?) -> String? {
        let container = base ?? Self.appGroupBase()
        let url = container.appendingPathComponent(fileName)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func appGroupBase() -> URL {
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: LocalStore.appGroupID)
        return container ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }
}
