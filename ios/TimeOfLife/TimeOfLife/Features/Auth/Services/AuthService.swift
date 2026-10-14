import Foundation
import Combine

/// Orchestrates `AuthRepository` + `KeychainStoring` + `SessionCache` +
/// `SessionStore`. Owns the token lifecycle: writes Keychain + cache on
/// OTP verify, rotates on refresh, clears all on logout.
///
/// `restoreSession()`: reads Keychain+cache, attempts `/me` in background;
/// on transient offline failure keeps the cached session (no logout on
/// offline). Logout works offline — clears local, best-effort server revoke.
@MainActor
final class AuthService: ObservableObject {
    let repository: AuthRepository
    let keychain: KeychainStoring
    let cache: SessionCache
    let sessionStore: SessionStore

    /// Single-flight in-flight refresh task. Concurrent callers of
    /// `performRefresh` share one network refresh so that token rotation
    /// (which revokes the old refresh token on the server) isn't raced: a
    /// second concurrent refresh would read the now-revoked token, trip the
    /// server's reuse detection, and revoke every session for the user.
    private var refreshTask: Task<String, Error>?

    init(
        repository: AuthRepository,
        keychain: KeychainStoring,
        cache: SessionCache,
        sessionStore: SessionStore
    ) {
        self.repository = repository
        self.keychain = keychain
        self.cache = cache
        self.sessionStore = sessionStore
    }

    // MARK: - Public API (called by ViewModels / RootView)

    /// `POST /auth/otp/request`. Normalizes the email and caches it (in-memory)
    /// so the OTP screen knows which address is being verified and the email
    /// field is restored if the user navigates back. Always 202 on success —
    /// no account enumeration.
    func requestOtp(email: String) async throws {
        let normalized = AuthValidator.normalize(email: email)
        try await repository.requestOtp(email: normalized)
        sessionStore.setCachedEmail(normalized)
    }

    /// `POST /auth/otp/verify`. Persists the returned session (tokens →
    /// Keychain, user → cache + SessionStore) on success.
    func verifyOtp(email: String, code: String) async throws {
        let normalized = AuthValidator.normalize(email: email)
        let session = try await repository.verifyOtp(email: normalized, code: code)
        await persist(session: session)
    }

    /// `POST /auth/apple`. Exchanges Apple's identity token for a session and
    /// persists it (same path as `verifyOtp` → flips `SessionStore` → signed-in).
    func signInWithApple(identityToken: String) async throws {
        let session = try await repository.appleSignIn(identityToken: identityToken)
        await persist(session: session)
    }

    /// Reads Keychain + cache; if a refresh token exists, attempts `/me`.
    /// On transient non-auth failures (offline, 5xx, transport) keeps the
    /// cached session. Only `unauthorized` after a failed refresh clears local state.
    func restoreSession() async {
        // The gate holds a blank background (not the auth flow) while this
        // is unresolved — set on entry (re-entrant safe) and always cleared,
        // so a slow/offline restore can never stick the gate. Cached
        // sessions clear it early (optimistic launch above).
        sessionStore.setRestoring(true)
        defer { sessionStore.setRestoring(false) }
        let cached = cache.load()
        let refreshToken = await keychain.string(for: .refreshToken)

        // If we have a cached session and tokens, optimistically show signed-in.
        if let cached, refreshToken != nil {
            // Re-save: refreshes the resolver sidecar file even when `/me`
            // below never runs (offline), so extension surfaces resolve
            // from the first cold start after upgrade, not just fresh sign-in.
            cache.save(cached)
            sessionStore.setSignedIn(cached)
            // Optimistic launch (steady-track-launch): the gate proceeds on
            // the cached session without waiting for `/me` — validation
            // continues below while the shell prepares underneath. The entry
            // `setRestoring(true)` + trailing `defer` stay as backstop.
            // No-cache launches keep holding until `/me` resolves, so a
            // slow first resolve never flashes the auth flow.
            sessionStore.setRestoring(false)
        }

        guard refreshToken != nil else { return }

        // Validate against the server. On failure:
        // - offline → keep cached session.
        // - 401 → try refresh; if that fails, sign out.
        do {
            let user = try await repository.me()
            let updated = CachedSession(
                id: user.id,
                email: user.email,
                emailVerified: user.emailVerified
            )
            cache.save(updated)
            sessionStore.setSignedIn(updated)
        } catch APIError.unauthorized {
            // APIClient already attempted one transparent refresh. Keep this
            // fallback for repository implementations that report the 401
            // directly; a failed refresh clears the token before this path
            // runs, so it cannot submit the revoked token a second time.
            do {
                _ = try await performRefresh()
            } catch {
                await clearLocal()
            }
        } catch {
            // Keep the cached session on any non-auth failure (offline, transient
            // 5xx, transport blips). Only a confirmed unauthorized response after
            // a failed refresh, or explicit logout, should clear local state.
        }
    }

    /// Refresh helper exposed for `APIClient`'s refresh hook. Rotates tokens
    /// and persists the new pair. Returns the new access token.
    ///
    /// Single-flight: if a refresh is already in progress, concurrent callers
    /// await the same in-flight `Task` instead of starting a second network
    /// refresh. The server rotates (and revokes) the refresh token on each
    /// refresh, so two concurrent refreshes would have the second use the
    /// just-revoked token, trip reuse detection, and revoke all the user's
    /// sessions — a benign race that logs the user out everywhere. The
    /// in-flight task is assigned before the first `await`, so a caller that
    /// arrives while the refresh is running always joins rather than starts
    /// its own.
    func performRefresh() async throws -> String {
        if let existing = refreshTask {
            return try await existing.value
        }
        let task = Task<String, Error> { [self] in
            guard let refresh = await self.keychain.string(for: .refreshToken) else {
                throw APIError.unauthorized
            }
            let session = try await self.repository.refresh(refreshToken: refresh)
            await self.persist(session: session)
            return session.accessToken
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            return try await task.value
        } catch APIError.unauthorized {
            // A rejected or reused refresh token cannot recover locally. Clear
            // the cached session immediately so RootView returns to sign-in.
            await clearLocal()
            throw APIError.unauthorized
        }
    }

    /// Logout. Clears local state always; best-effort server revoke.
    func logout() async {
        do {
            try await repository.logout()
        } catch {
            // Best-effort: ignore network/401 — we still clear local state.
        }
        await clearLocal()
    }

    // MARK: - Internals

    private func persist(session: AuthSession) async {
        await keychain.setString(session.accessToken, for: .accessToken)
        await keychain.setString(session.refreshToken, for: .refreshToken)
        let cached = CachedSession(id: session.user.id, email: session.user.email,
                                   emailVerified: session.user.emailVerified)
        cache.save(cached)
        sessionStore.setSignedIn(cached)
    }

    private func clearLocal() async {
        await keychain.remove(key: .accessToken)
        await keychain.remove(key: .refreshToken)
        cache.clear()
        sessionStore.setSignedOut()
    }
}
