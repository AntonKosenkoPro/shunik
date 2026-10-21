import Testing
import Foundation
@testable import TimeOfLife

@MainActor
@Suite("AuthService")
struct AuthServiceTests {

    private func makeService(
        initialSnapshot: CredentialSnapshot? = nil,
        cached: CachedSession? = nil
    ) -> (AuthService, FakeAuthRepository, InMemoryKeychainStore, SessionCache, SessionStore) {
        let repo = FakeAuthRepository()
        let keychain = InMemoryKeychainStore(snapshot: initialSnapshot)
        let cache = SessionCache(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        if let cached { cache.save(cached) }
        let store = SessionStore()
        let service = AuthService(
            repository: repo,
            keychain: keychain,
            cache: cache,
            sessionStore: store
        )
        return (service, repo, keychain, cache, store)
    }

    private func tokens(_ keychain: InMemoryKeychainStore) async -> (access: String?, refresh: String?) {
        let snapshot = await TestFactories.snapshotTokens(keychain)
        return (snapshot.access, snapshot.refresh)
    }

    private func waitForRefreshSend(_ repo: FakeAuthRepository) async throws {
        try await TestFactories.waitForRefreshSend(repo)
    }

    // MARK: - requestOTP

    @Test("requestOTP normalizes email, caches it, and writes no tokens on success")
    func requestOtpSuccess() async throws {
        let (service, repo, keychain, _, store) = makeService()

        try await service.requestOtp(email: "  Foo@Bar.com ")

        #expect(repo.calls == [.requestOtp(email: "foo@bar.com")])
        #expect(await tokens(keychain) == (nil, nil))
        #expect(store.cachedEmail == "foo@bar.com")
    }

    @Test("requestOTP propagates network failure")
    func requestOtpNetworkFailure() async throws {
        let (service, repo, _, _, _) = makeService()
        repo.otpRequestError = APIError.offline

        do {
            try await service.requestOtp(email: "a@b.com")
            Issue.record("Expected error to be thrown")
        } catch let error as APIError {
            #expect(error == .offline)
        }
    }

    // MARK: - verifyOTP

    @Test("verifyOTP persists tokens and caches session on success")
    func verifyOtpSuccess() async throws {
        let (service, repo, keychain, cache, store) = makeService()

        try await service.verifyOtp(email: "a@b.com", code: "123456")

        #expect(repo.calls == [.verifyOtp(email: "a@b.com", code: "123456")])
        #expect(await tokens(keychain) == ("at", "rt"))
        #expect(cache.load()?.email == "a@b.com")
        #expect(
            store.state == .signedIn(
                CachedSession(id: "u1", email: "a@b.com", emailVerified: true)
            )
        )
    }

    @Test("verifyOTP propagates invalid code error")
    func verifyOtpInvalidCode() async throws {
        let (service, repo, _, _, _) = makeService()
        repo.otpVerifyError = APIError.server(code: "invalid_otp", message: "Incorrect code. Try again.")

        do {
            try await service.verifyOtp(email: "a@b.com", code: "000000")
            Issue.record("Expected error to be thrown")
        } catch let error as APIError {
            #expect(error.code == "invalid_otp")
        }
    }

    @Test("verifyOTP propagates expired code error")
    func verifyOtpExpiredCode() async throws {
        let (service, repo, _, _, _) = makeService()
        repo.otpVerifyError = APIError.server(
            code: "otp_expired",
            message: "This code has expired. Request a new one."
        )

        do {
            try await service.verifyOtp(email: "a@b.com", code: "123456")
            Issue.record("Expected error to be thrown")
        } catch let error as APIError {
            #expect(error.code == "otp_expired")
        }
    }

    @Test("verifyOTP propagates attempts exceeded error")
    func verifyOtpAttemptsExceeded() async throws {
        let (service, repo, _, _, _) = makeService()
        repo.otpVerifyError = APIError.server(
            code: "otp_attempts_exceeded",
            message: "Too many attempts. Request a new code."
        )

        do {
            try await service.verifyOtp(email: "a@b.com", code: "123456")
            Issue.record("Expected error to be thrown")
        } catch let error as APIError {
            #expect(error.code == "otp_attempts_exceeded")
        }
    }

    // MARK: - logout

    @Test("logout clears local state even if server call fails")
    func logoutClearsLocal() async throws {
        let (service, repo, keychain, cache, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt"),
            cached: CachedSession(id: "u1", email: "a@b.com", emailVerified: true)
        )
        repo.logoutError = APIError.offline

        await service.logout()

        #expect(await tokens(keychain) == (nil, nil))
        #expect(cache.load() == nil)
        #expect(store.state == .signedOut)
    }

    @Test("logout resets state to unauthenticated")
    func logoutResetsState() async throws {
        let (service, _, keychain, cache, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt"),
            cached: CachedSession(id: "u1", email: "a@b.com", emailVerified: true)
        )

        await service.logout()

        #expect(await tokens(keychain) == (nil, nil))
        #expect(cache.load() == nil)
        #expect(store.state == .signedOut)
    }

    // MARK: - restoreSession

    @Test("restoreSession restores authenticated state when tokens are valid")
    func restoreSessionAuthenticated() async throws {
        let cached = CachedSession(id: "u1", email: "a@b.com", emailVerified: true)
        let (service, repo, _, cache, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt"),
            cached: cached
        )
        // me() succeeds by default

        await service.restoreSession()

        // Optimistically signed-in from cache, then /me confirms
        #expect(store.state == .signedIn(cached))
        #expect(cache.load() == cached)
        #expect(repo.calls.contains(.me))
    }

    @Test("restoreSession stays unauthenticated when no tokens exist")
    func restoreSessionNoTokens() async throws {
        let (service, _, _, _, store) = makeService()

        await service.restoreSession()

        #expect(store.state == .signedOut)
    }

    // MARK: - Gate transitions (account-bound-local-data 2.4)

    /// The gate decides on `SessionStore.state` alone; every launch path
    /// (no session → gate, restored session → shell, revocation → gate)
    /// must land in the right state. Data-file assertions live in task 3.x.

    @Test("revoked session locks to the gate: signed out, tokens cleared, cache cleared")
    func revokedSessionLocksToGate() async throws {
        let cached = CachedSession(id: "u1", email: "a@b.com", emailVerified: true)
        let (service, repo, keychain, cache, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt"),
            cached: cached
        )
        repo.meError = APIError.unauthorized
        repo.refreshError = APIError.server(code: "invalid_refresh", message: "expired")
        await service.restoreSession()

        #expect(store.state == .signedOut)
        #expect(await tokens(keychain) == (nil, nil))
        #expect(cache.load() == nil)
    }

    @Test("transient offline restore keeps the signed-in shell mounted")
    func offlineRestoreKeepsGateDown() async throws {
        let cached = CachedSession(id: "u1", email: "a@b.com", emailVerified: true)
        let (service, repo, _, _, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt"),
            cached: cached
        )
        repo.meError = APIError.offline
        await service.restoreSession()

        // Offline is not an auth fact: the shell stays (D6 lock-not-wipe).
        #expect(store.state == .signedIn(cached))
    }

    @Test("restoreSession keeps cached session on offline /me failure")
    func restoreOfflineKeepsCached() async throws {
        let cached = CachedSession(id: "u1", email: "a@b.com", emailVerified: true)
        let (service, repo, _, cache, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt"),
            cached: cached
        )
        repo.meError = APIError.offline

        await service.restoreSession()

        #expect(store.state == .signedIn(cached))
        #expect(cache.load() == cached)
    }

    @Test("restoreSession keeps cached session on transient server error")
    func restoreSessionKeepsCachedOnServerError() async throws {
        let cached = CachedSession(id: "u1", email: "a@b.com", emailVerified: true)
        let (service, repo, keychain, cache, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt"),
            cached: cached
        )
        repo.meError = APIError.server(code: "http_500", message: "Internal server error")

        await service.restoreSession()

        #expect(store.state == .signedIn(cached))
        #expect(cache.load() == cached)
        #expect(await tokens(keychain) == ("at", "rt"))
    }

    @Test("restore locks the gate on 401 with no rotation landed (restore sends no refresh of its own)")
    func restore401WithoutRotationLocksGate() async throws {
        let cached = CachedSession(id: "u1", email: "a@b.com", emailVerified: true)
        let (service, repo, keychain, _, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt"),
            cached: cached
        )
        repo.meError = APIError.unauthorized
        repo.refreshError = APIError.server(code: "invalid_refresh", message: "expired")

        await service.restoreSession()

        #expect(await tokens(keychain) == (nil, nil))
        #expect(store.state == .signedOut)
        #expect(repo.refreshSends.isEmpty, "restore must not start its own refresh; APIClient owns the single retry")
    }

    // MARK: - performRefresh

    @Test("performRefresh rotates tokens and returns new access token")
    func performRefresh() async throws {
        let (service, repo, keychain, _, _) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt")
        )

        let new = try await service.performRefresh()

        #expect(new == "at2")
        #expect(await tokens(keychain) == ("at2", "rt2"))
        #expect(repo.refreshSends.count == 1)
        #expect(repo.refreshSends.first?.refreshToken == "rt")
        #expect(!(repo.refreshSends.first?.attemptId.isEmpty ?? true), "an attempt id is always sent")
    }

    @Test("performRefresh throws unauthorized when no refresh token")
    func performRefreshNoToken() async throws {
        let cached = CachedSession(id: "u1", email: "a@b.com", emailVerified: true)
        let (service, _, keychain, cache, store) = makeService(cached: cached)

        do {
            _ = try await service.performRefresh()
            Issue.record("Expected unauthorized error")
        } catch let error as APIError {
            #expect(error == .unauthorized)
        }
        #expect(await tokens(keychain) == (nil, nil))
        #expect(cache.load() == nil)
        #expect(store.state == .signedOut)
    }

    @Test("performRefresh signs out when the server rejects the refresh token")
    func performRefreshRejectedTokenSignsOut() async throws {
        let cached = CachedSession(id: "u1", email: "a@b.com", emailVerified: true)
        let (service, repo, keychain, cache, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "expired", refreshToken: "revoked"),
            cached: cached
        )
        repo.refreshError = APIError.unauthorized

        do {
            _ = try await service.performRefresh()
            Issue.record("Expected unauthorized error")
        } catch let error as APIError {
            #expect(error == .unauthorized)
        }
        #expect(await tokens(keychain) == (nil, nil))
        #expect(cache.load() == nil)
        #expect(store.state == .signedOut)
    }

    @Test("performRefresh coalesces concurrent refreshes into one network call (single-flight)")
    func performRefreshSingleFlight() async throws {
        let (service, repo, _, _, _) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt")
        )
        // Hold the refresh on the gate so the first call stays in-flight long
        // enough for the second to arrive and have to join it.
        repo.refreshGateHeld = true

        // Start two refreshes concurrently.
        async let first = service.performRefresh()
        async let second = service.performRefresh()

        // Wait until the in-flight refresh has recorded its single network call.
        try await waitForRefreshSend(repo)
        // While the first refresh is still gated, only ONE network refresh
        // must have happened — the second caller joined the in-flight task
        // instead of starting its own (which would revoke the shared token).
        #expect(repo.refreshSends.count == 1, "expected a single in-flight refresh")

        repo.releaseRefreshGate()
        let (tokenA, tokenB) = try await (first, second)

        #expect(tokenA == "at2")
        #expect(tokenB == "at2")
        // Still exactly one network refresh after both callers complete, and
        // both shared its single durable attempt.
        #expect(repo.refreshSends.count == 1)
    }
}
