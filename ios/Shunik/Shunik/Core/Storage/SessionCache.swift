import Foundation

/// Persists non-secret session metadata (`user id`, `email`) in `UserDefaults`
/// so the UI can render a cached session after a cold launch, before `/me`
/// resolves. Tokens never go here — only `KeychainStoring`.
///
/// Additionally mirrors the user id into a sidecar file
/// (`ActiveAccountFileResolver.sessionFileName`) when `sessionFileURL` is
/// set (production App Group container): extension processes cannot reliably
/// read suite `UserDefaults` (`cfprefsd` detaches), but group-container file
/// reads stay reliable — that file is what cross-process surfaces resolve.
/// Nil (tests, previews, UI-testing) keeps defaults-only behavior.
///
/// Thread-safe via a serial `DispatchQueue`.
final class SessionCache: @unchecked Sendable {
    private let defaults: UserDefaults
    private let sessionFileURL: URL?
    private let queue = DispatchQueue(label: "com.shunik.SessionCache")

    init(defaults: UserDefaults = .standard, sessionFileURL: URL? = nil) {
        self.defaults = defaults
        self.sessionFileURL = sessionFileURL
    }

    func save(_ session: CachedSession?) {
        queue.sync {
            if let session {
                defaults.set(session.id, forKey: Keys.id)
                defaults.set(session.email, forKey: Keys.email)
                defaults.set(session.emailVerified, forKey: Keys.emailVerified)
                mirrorSessionFile(userID: session.id)
            } else {
                defaults.removeObject(forKey: Keys.id)
                defaults.removeObject(forKey: Keys.email)
                defaults.removeObject(forKey: Keys.emailVerified)
                mirrorSessionFile(userID: nil)
            }
        }
    }

    /// Writes (sign-in) or removes (sign-out) the resolver sidecar.
    /// Best-effort: a failed write must never fail the sign-in itself.
    /// The sidecar is read by lock-screen extension surfaces with a locked
    /// keybag, so it carries the same after-first-unlock class as the db.
    /// A failed sign-out removal falls back to blanking the file: a stale
    /// id would otherwise keep resolving the logged-out account (and a
    /// lock-screen intent could write into it), while a blank file
    /// resolves `.locked` — the safe direction.
    private func mirrorSessionFile(userID: String?) {
        guard let url = sessionFileURL else { return }
        if let userID {
            try? userID.write(to: url, atomically: true, encoding: .utf8)
            FileManager.default.ensureAccessibleAfterFirstUnlock(url)
        } else {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                try? "".write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    func load() -> CachedSession? {
        queue.sync {
            guard let id = defaults.string(forKey: Keys.id),
                  let email = defaults.string(forKey: Keys.email) else { return nil }
            let verified = defaults.bool(forKey: Keys.emailVerified)
            return CachedSession(id: id, email: email, emailVerified: verified)
        }
    }

    func clear() {
        save(nil)
    }

    private enum Keys {
        static let id = "com.shunik.session.id"
        static let email = "com.shunik.session.email"
        static let emailVerified = "com.shunik.session.emailVerified"
    }
}

/// The subset of `AuthSession` cached on disk (no secrets).
struct CachedSession: Equatable, Codable, Sendable {
    let id: String
    let email: String
    let emailVerified: Bool
}
