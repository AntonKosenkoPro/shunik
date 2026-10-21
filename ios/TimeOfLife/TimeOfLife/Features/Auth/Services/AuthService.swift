// swiftlint:disable file_length
import Foundation
import Combine

/// Orchestrates `AuthRepository` + `KeychainStoring` + `SessionCache` +
/// `SessionStore`. Owns the token lifecycle: writes Keychain + cache on
/// OTP verify, rotates on refresh, clears all on logout.
///
/// Credentials persist as one durable `CredentialSnapshot` (a single
/// status-checked Keychain write — never split access-then-refresh writes,
/// so a restart never observes a mixed pair). Each logical rotation mints
/// one unpredictable refresh-attempt id, persisted BEFORE the network send
/// and reused across suspension/restart until a complete successor snapshot
/// is durably saved — a committed-but-undelivered rotation is reclaimed
/// instead of tripping reuse detection.
///
/// `restoreSession()`: reads snapshot+cache, attempts `/me` in background;
/// on transient offline failure keeps the cached session (no logout on
/// offline). The one transparent refresh for that request lives inside
/// `APIClient` — restore never launches a second one. Logout works offline —
/// clears local, best-effort server revoke.
@MainActor
final class AuthService: ObservableObject {
    let repository: AuthRepository
    let keychain: KeychainStoring
    let cache: SessionCache
    let sessionStore: SessionStore

    /// Single-flight in-flight refresh task. Concurrent callers of
    /// `performRefresh` share one network refresh — and therefore one durable
    /// attempt — so that token rotation (which revokes the old refresh token
    /// on the server) isn't raced: a second concurrent refresh would present
    /// the now-revoked predecessor with a different attempt, trip the
    /// server's reuse detection, and revoke the device's session.
    /// The in-flight task is assigned before the first `await`, so a caller
    /// that arrives while the refresh is running always joins rather than
    /// starts its own.
    private var refreshTask: Task<String, Error>?

    /// Generation captured with the in-flight refresh. A caller joins the
    /// in-flight task only when its own generation still matches: after a
    /// sign-out/switch the stale task is already unwinding, and joining it
    /// would surface a spurious cancellation instead of starting the fresh
    /// attempt the new session needs.
    private var refreshTaskGeneration: UInt64?

    /// Active account generation. Bumped on every sign-in and sign-out, so a
    /// refresh completing after sign-out/account switch is dropped and never
    /// writes into (or clears) the new session. Process-lifetime only:
    /// restarts have no in-flight completions, and intent reuse then keys off
    /// the persisted predecessor + attempt instead.
    private var sessionGeneration: UInt64 = 0

    /// Builds unpredictable refresh-attempt ids. Injected so tests can mint
    /// deterministic ids when needed.
    private let attemptIDGenerator: @Sendable () -> String

    init(
        repository: AuthRepository,
        keychain: KeychainStoring,
        cache: SessionCache,
        sessionStore: SessionStore,
        attemptIDGenerator: @escaping @Sendable () -> String = { RefreshAttempt.newID() }
    ) {
        self.repository = repository
        self.keychain = keychain
        self.cache = cache
        self.sessionStore = sessionStore
        self.attemptIDGenerator = attemptIDGenerator
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

    /// `POST /auth/otp/verify`. Persists the returned session (snapshot →
    /// Keychain, user → cache + SessionStore) on success. Fails closed: a
    /// failed snapshot write publishes nothing and stays signed out.
    func verifyOtp(email: String, code: String) async throws {
        let normalized = AuthValidator.normalize(email: email)
        let session = try await repository.verifyOtp(email: normalized, code: code)
        try await persistSignIn(session: session)
    }

    /// `POST /auth/apple`. Exchanges Apple's identity token for a session and
    /// persists it (same path as `verifyOtp` → flips `SessionStore` → signed-in).
    func signInWithApple(identityToken: String) async throws {
        let session = try await repository.appleSignIn(identityToken: identityToken)
        try await persistSignIn(session: session)
    }

    /// Reads snapshot + cache; if a refresh token exists, attempts `/me`.
    /// On transient non-auth failures (offline, 5xx, transport) keeps the
    /// cached session. On a 401, the single transparent refresh already ran
    /// inside `APIClient`: local state is cleared only when that outcome was
    /// conclusive (no rotation landed); a landed rotation or an unreadable
    /// store keeps the cached session.
    func restoreSession() async {
        // The gate holds a blank background (not the auth flow) while this
        // is unresolved — set on entry (re-entrant safe) and always cleared,
        // so a slow/offline restore can never stick the gate. Cached
        // sessions clear it early (optimistic launch above).
        sessionStore.setRestoring(true)
        defer { sessionStore.setRestoring(false) }
        let cached = cache.load()
        let entryRefresh: String?
        switch await keychain.loadSnapshot() {
        case .failure:
            // Storage temporarily unreadable: keep the cached session and
            // attempt nothing — this is "unavailable, keep retry intent",
            // not "no session".
            if let cached {
                cache.save(cached)
                sessionStore.setSignedIn(cached)
                sessionStore.setRestoring(false)
            }
            return
        case .success(let snapshot):
            entryRefresh = snapshot?.refreshToken
            // If we have a cached session and tokens, optimistically show signed-in.
            if let cached, entryRefresh != nil {
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
        }

        guard let entryRefresh else { return }

        // Validate against the server. On failure:
        // - offline → keep cached session.
        // - 401 → the single owned refresh already ran inside APIClient (see
        //   performRefresh); clear only when it conclusively failed.
        do {
            let user = try await repository.me()
            let updated = CachedSession(
                id: user.id,
                email: user.email,
                emailVerified: user.emailVerified
            )
            cache.save(updated)
            sessionStore.setSignedIn(updated)
        } catch APIError.unauthorized, APIError.authenticationRejected {
            switch await keychain.loadSnapshot() {
            case .success(let current) where current?.refreshToken != entryRefresh:
                // A rotation landed under us (or state moved on): the retry's
                // 401 is not a verdict on the new credentials — keep the
                // cached session instead of wiping fresh credentials.
                break
            case .success:
                await clearLocal()
            case .failure:
                // Storage unavailable: keep retry intent, never wipe.
                break
            }
        } catch {
            // Keep the cached session on any non-auth failure (offline, transient
            // 5xx, transport blips). Only a confirmed unauthorized response after
            // a conclusively failed refresh, or explicit logout, clears local state.
        }
    }

    /// Refresh helper exposed for `APIClient`'s refresh hook. Rotates tokens
    /// and persists the new pair. Returns the new access token.
    ///
    /// Single-flight: if a refresh is already in progress, concurrent callers
    /// await the same in-flight `Task` instead of starting a second network
    /// refresh (see `refreshTask`). The shared task mints one durable attempt
    /// for the logical rotation and every concurrent caller shares it.
    func performRefresh() async throws -> String {
        let generation = sessionGeneration
        if let existing = refreshTask, refreshTaskGeneration == generation {
            return try await existing.value
        }
        let task = Task<String, Error> { [self] in
            try await self.runRefresh(generation: generation)
        }
        refreshTask = task
        refreshTaskGeneration = generation
        defer {
            if refreshTaskGeneration == generation {
                refreshTask = nil
                refreshTaskGeneration = nil
            }
        }
        return try await task.value
    }

    /// Logout. Cancels any in-flight refresh (its completion is dropped by
    /// the generation guard), then clears local state always; best-effort
    /// server revoke.
    func logout() async {
        refreshTask?.cancel()
        do {
            try await repository.logout()
        } catch {
            // Best-effort: ignore network/401 — we still clear local state.
        }
        await clearLocal()
    }

    // MARK: - Refresh lifecycle

    /// One logical rotation: load (or mint + persist) the attempt, send once
    /// with the attempt id, then durably replace the snapshot. Completions
    /// from an older account generation are dropped, never written into the
    /// new session.
    private func runRefresh(generation: UInt64) async throws -> String {
        let intent: RefreshIntent
        do {
            intent = try await loadRefreshIntent()
        } catch APIError.unauthorized where generation == sessionGeneration {
            // Absent credentials = no session: clear and report, as before.
            await clearLocal()
            throw APIError.unauthorized
        }
        let session: AuthSession
        do {
            session = try await repository.refresh(
                refreshToken: intent.predecessor,
                attemptId: intent.attemptId
            )
        } catch {
            return try await mapRefreshFailure(error, generation: generation)
        }
        // A sign-out/switch that landed mid-flight invalidates this
        // completion: drop it instead of writing into the new session.
        guard generation == sessionGeneration else {
            throw CancellationError()
        }
        return try await persistRefresh(session: session, prior: intent.snapshot, generation: generation)
    }

    /// Durable refresh intent: the predecessor to present plus the attempt to
    /// present it with. Reuses the persisted attempt while the durable
    /// predecessor still matches; otherwise mints one unpredictable id and
    /// persists it BEFORE any network send. A failed intent write sends
    /// nothing and keeps the existing credentials.
    private func loadRefreshIntent() async throws -> RefreshIntent {
        let snapshot: CredentialSnapshot
        switch await keychain.loadSnapshot() {
        case .success(let loaded):
            guard let loaded, !loaded.refreshToken.isEmpty else {
                throw APIError.unauthorized
            }
            snapshot = loaded
        case .failure(let error):
            throw APIError.storage(underlying: error.localizedDescription)
        }
        if let attempt = snapshot.pendingAttemptId,
           snapshot.pendingPredecessor == snapshot.refreshToken {
            return RefreshIntent(predecessor: snapshot.refreshToken, attemptId: attempt, snapshot: snapshot)
        }
        let attempt = attemptIDGenerator()
        var intent = snapshot
        intent.pendingAttemptId = attempt
        intent.pendingPredecessor = snapshot.refreshToken
        switch await keychain.saveSnapshot(intent) {
        case .success:
            return RefreshIntent(predecessor: snapshot.refreshToken, attemptId: attempt, snapshot: intent)
        case .failure(let error):
            throw APIError.storage(underlying: error.localizedDescription)
        }
    }

    /// Maps a failed refresh send onto the failure taxonomy. Confirmed
    /// revocation/exhaustion clears local state (generation-guarded); a
    /// closed duplicate is ignored in favor of the durable credentials;
    /// everything ambiguous is rethrown with credentials and retry intent
    /// kept. Never signs out on an ambiguous failure.
    private func mapRefreshFailure(_ error: Error, generation: UInt64) async throws -> String {
        if error is CancellationError {
            throw CancellationError()
        }
        // A sign-out/switch that landed mid-flight: drop, never touch the
        // new session — not even to clear it.
        guard generation == sessionGeneration else {
            throw CancellationError()
        }
        guard let apiError = error as? APIError else {
            throw APIError.transport(underlying: String(describing: error))
        }
        switch apiError {
        case let .server(code, _, _), let .authenticationRejected(code, _, _):
            if code == RefreshAttempt.completedCode {
                return try await currentAccessToken(fallback: apiError)
            }
            if RefreshAttempt.revocationCodes.contains(code) {
                await clearLocal()
            }
            throw apiError
        case .unauthorized:
            // Bare rejection (envelope-less 401): conclusive, as before.
            await clearLocal()
            throw apiError
        default:
            // Offline / transport / decoding / storage / service /
            // unexpected: ambiguous — keep credentials and retry intent.
            throw apiError
        }
    }

    /// Closed-duplicate recovery: a delayed `refresh_attempt_completed`
    /// belongs to an attempt older than the durable snapshot, so it is
    /// ignored and the caller continues with the current credentials
    /// instead of signing out.
    private func currentAccessToken(fallback: Error) async throws -> String {
        switch await keychain.loadSnapshot() {
        case .success(let snapshot):
            if let token = snapshot?.accessToken, !token.isEmpty {
                return token
            }
            // CancellationError is reserved for genuinely superseded
            // refreshes; an empty durable access token is an auth-state
            // failure the caller must see, not a cancellation it may
            // silently swallow.
            throw fallback
        case .failure:
            throw fallback
        }
    }

    /// Durably replaces the snapshot with the complete successor and clears
    /// the attempt. A failed replacement keeps the predecessor + attempt for
    /// later recovery and serves only the in-memory token for this call —
    /// nothing half-written is ever published as durable success. The
    /// generation is re-validated after the save: a sign-out/switch that
    /// landed while the save was in flight must not resurrect the superseded
    /// session by publishing afterwards.
    private func persistRefresh(session: AuthSession, prior: CredentialSnapshot, generation: UInt64) async throws -> String {
        let successor = CredentialSnapshot(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            accountId: session.user.id,
            deviceId: prior.deviceId,
            pendingAttemptId: nil,
            pendingPredecessor: nil
        )
        if case .success = await keychain.saveSnapshot(successor) {
            guard generation == sessionGeneration else {
                throw CancellationError()
            }
            let cached = CachedSession(
                id: session.user.id,
                email: session.user.email,
                emailVerified: session.user.emailVerified
            )
            cache.save(cached)
            sessionStore.setSignedIn(cached)
        }
        return session.accessToken
    }

    // MARK: - Internals

    /// Sign-in persistence (verify / Apple): fails closed — nothing is
    /// published (no cache write, no signed-in flip) until the complete
    /// snapshot is durably saved.
    private func persistSignIn(session: AuthSession) async throws {
        sessionGeneration &+= 1
        let snapshot = CredentialSnapshot(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            accountId: session.user.id,
            deviceId: await keychain.string(for: .deviceId),
            pendingAttemptId: nil,
            pendingPredecessor: nil
        )
        switch await keychain.saveSnapshot(snapshot) {
        case .success:
            let cached = CachedSession(
                id: session.user.id,
                email: session.user.email,
                emailVerified: session.user.emailVerified
            )
            cache.save(cached)
            sessionStore.setSignedIn(cached)
        case .failure(let error):
            throw APIError.storage(underlying: error.localizedDescription)
        }
    }

    private func clearLocal() async {
        sessionGeneration &+= 1
        await keychain.removeSnapshot()
        cache.clear()
        sessionStore.setSignedOut()
    }
}

/// The durable inputs to one refresh send: which predecessor to present,
/// with which attempt, against which snapshot generation the completion
/// must be applied.
private struct RefreshIntent: Sendable {
    let predecessor: String
    let attemptId: String
    let snapshot: CredentialSnapshot
}
