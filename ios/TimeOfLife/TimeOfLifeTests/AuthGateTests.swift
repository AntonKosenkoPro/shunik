import Testing
import Foundation
@testable import TimeOfLife

/// Auth-gate behavior tests (account-bound-local-data task 2.4,
/// repurposed from `EnableSyncPresenterTests`): the same restore/gate
/// transition paths the old presenter branched on now drive the full-screen
/// gate — `SessionStore.state` is the only surface that decides, so the
/// service-level transitions are what a signed-out-vs-signed-in launch and a
/// logout-return-to-gate rest on. Files/data assertions belong to the
/// per-account store group (task 3.x).
@MainActor
@Suite("AuthGate")
struct AuthGateTests {

    private func makeService(
        initialSnapshot: CredentialSnapshot? = nil,
        cached: CachedSession? = nil
    ) -> (AuthService, FakeAuthRepository, InMemoryKeychainStore, SessionCache, SessionStore) {
        let repository = FakeAuthRepository()
        let keychain = InMemoryKeychainStore(snapshot: initialSnapshot)
        let cache = SessionCache(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        if let cached { cache.save(cached) }
        let store = SessionStore()
        let service = AuthService(
            repository: repository,
            keychain: keychain,
            cache: cache,
            sessionStore: store
        )
        return (service, repository, keychain, cache, store)
    }

    private func tokens(_ keychain: InMemoryKeychainStore) async -> (access: String?, refresh: String?) {
        let snapshot = await TestFactories.snapshotTokens(keychain)
        return (snapshot.access, snapshot.refresh)
    }

    // MARK: - Launch gate (restore transitions)

    @Test("restore with a restorable session signs in — gate is replaced by the shell")
    func restoreWithTokensSignsIn() async {
        let cached = CachedSession(id: "u1", email: "a@b.com", emailVerified: true)
        let (service, _, _, _, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt"),
            cached: cached
        )

        await service.restoreSession()

        guard case .signedIn = store.state else {
            Issue.record("expected signed-in after restore, got \(store.state)")
            return
        }
    }

    @Test("restore without a session leaves the gate up (never a silent no-op into the shell)")
    func restoreWithoutTokensStaysSignedOut() async {
        let (service, repo, _, _, store) = makeService()

        await service.restoreSession()

        #expect(store.state == .signedOut)
        #expect(repo.calls.isEmpty, "no network traffic without a refresh token")
    }

    @Test("restore with a token but no cache still restores via /me")
    func restoreTokenWithoutCache() async {
        let (service, repo, _, _, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt")
        )

        await service.restoreSession()

        #expect(repo.calls.contains(.me))
        guard case .signedIn(let session) = store.state else {
            Issue.record("expected signed-in via /me, got \(store.state)")
            return
        }
        #expect(session.id == "u1")
    }

    @Test("revoked/exhausted session locks to the gate (signs out), tokens cleared")
    func revokedSessionLocksToGate() async {
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

    // MARK: - Sign-out returns to the gate

    @Test("logout flips signed-in back to signedOut (gate re-renders)")
    func logoutReturnsToGate() async throws {
        let (service, _, keychain, _, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt"),
            cached: CachedSession(id: "u1", email: "a@b.com", emailVerified: true)
        )

        await service.logout()

        #expect(store.state == .signedOut)
        #expect(await tokens(keychain) == (nil, nil))
    }

    // MARK: - Restoring splash (fix-track-empty-after-reinstall 4.2)

    @Test("fresh store starts restoring (gate shows splash, never a login flash)")
    func freshStoreStartsRestoring() {
        #expect(SessionStore().isRestoring)
    }

    @Test("restore clears restoring with a restorable session")
    func restoreClearsRestoringWithSession() async {
        let cached = CachedSession(id: "u1", email: "a@b.com", emailVerified: true)
        let (service, _, _, _, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt"),
            cached: cached
        )

        await service.restoreSession()

        #expect(!store.isRestoring)
        guard case .signedIn = store.state else {
            Issue.record("expected signed-in after restore, got \(store.state)")
            return
        }
    }

    @Test("restore clears restoring without a session (auth, no stuck splash)")
    func restoreClearsRestoringWithoutSession() async {
        let (service, repo, _, _, store) = makeService()

        await service.restoreSession()

        #expect(!store.isRestoring)
        #expect(store.state == .signedOut)
        #expect(repo.calls.isEmpty, "no network traffic without a refresh token")
    }

    @Test("restoring stays up during a slow resolve, then clears")
    func restoringStaysUpDuringSlowResolve() async {
        // No cached session: restore must await the (slow) `/me` call with
        // the gate still signed-out — the reinstall login-flash window.
        let (service, repo, _, _, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt")
        )
        repo.meDelayNanoseconds = 300_000_000
        store.setRestoring(false)

        let restore = Task { await service.restoreSession() }
        await Task.yield()
        await Task.yield()
        let midFlight = store.isRestoring
        await restore.value

        #expect(midFlight, "splash stays up while /me is in flight")
        #expect(!store.isRestoring)
        guard case .signedIn = store.state else {
            Issue.record("expected signed-in via /me, got \(store.state)")
            return
        }
    }

    // MARK: - Failed bind keeps the gate up (Wave 5 re-review finding 1)

    @Test("a failed store bind reports failure without mounting (gate stays up)")
    func failedBindReportsWithoutMounting() async throws {
        let userID = "wave5-\(UUID().uuidString.lowercased())"
        let prodURL = LocalStore.databaseURL(userID: userID)
        // A corrupt file the open cannot migrate: a retryable (non-fatal)
        // failure, so `openLocalStore` reports instead of crashing.
        try Data("not-a-database".utf8).write(to: prodURL)
        defer {
            try? FileManager.default.removeItem(at: prodURL)
            for ext in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: prodURL.path + ext))
            }
        }
        let container = makeContainer()

        let opened = await container.openLocalStore(userID: userID)

        // The bind failed openly: no shell mount (`RootView` checks this
        // flag before setting its boundUserID), error surfaced for the gate.
        #expect(!opened)
        #expect(container.localStoreOpenError != nil)
        // The store is cleanly unbound: boundUserID nil, every op notBound.
        #expect(await container.localStore.boundUserID == nil)
        await #expect(throws: LocalStore.LocalStoreError.notBound) {
            try await container.localStore.outboxRows()
        }
    }

    /// Minimal production-shaped container for the bind-lifecycle tests
    /// (mirrors `AppContainer.uiTesting` wiring with unit-test doubles).
    private func makeContainer() -> AppContainer {
        let repository = FakeAuthRepository()
        let keychain = InMemoryKeychainStore()
        let cache = SessionCache(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sessionStore = SessionStore()
        let authService = AuthService(
            repository: repository,
            keychain: keychain,
            cache: cache,
            sessionStore: sessionStore
        )
        let localStore = LocalStore()
        let connectivity = MockConnectivity(connected: true)
        return AppContainer(
            baseURL: URL(string: "https://example.com")!,
            apiClient: APIClient(baseURL: URL(string: "https://example.com")!, session: .shared),
            keychain: keychain,
            sessionCache: cache,
            repository: repository,
            sessionStore: sessionStore,
            navigation: AppNavigationStack(),
            connectivity: connectivity,
            authService: authService,
            appleService: AppleSignInService(),
            localStore: localStore,
            undoBuffer: UndoBufferStore(store: localStore),
            syncController: SyncController(
                store: localStore,
                connectivity: connectivity
            ) { nil }
        )
    }
}
