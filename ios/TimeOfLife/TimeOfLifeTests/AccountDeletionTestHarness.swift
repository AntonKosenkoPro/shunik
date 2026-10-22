import Testing
import Foundation
@testable import TimeOfLife
import LifioLiveActivityCore

/// Shared harness for the account-deletion coordinator suites: fake network,
/// in-memory Keychain, isolated session cache with a throwaway sidecar, a
/// recording Live Activity controller, and a throwaway file base so scoped
/// erasure is asserted against real files without touching other tests.
@MainActor
final class RecordingLiveActivity: LiveActivityControlling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var endedOrphanedCalls = 0
    private(set) var endedRuns = 0
    func runStarted(text: String, iconSymbol: String, startedAt: Date, categoryChips: [LiveCategoryChip]) async {}
    func runEnded(startedAt: Date, durationSeconds: Int) async {
        incrementRuns()
    }
    func endOrphanedActivities(knownDurationSeconds: Int?) async {
        incrementOrphaned()
    }

    /// Synchronous lock dance (Swift 6 mode forbids direct `NSLock` use
    /// from async contexts).
    private func incrementRuns() {
        lock.lock(); endedRuns += 1; lock.unlock()
    }

    private func incrementOrphaned() {
        lock.lock(); endedOrphanedCalls += 1; lock.unlock()
    }
}

@MainActor
struct AccountDeletionHarness {
    let repo: FakeAuthRepository
    let keychain: InMemoryKeychainStore
    let cache: SessionCache
    let sessionStore: SessionStore
    let syncController: SyncController
    let store: LocalStore
    let timerService: TimerService
    let navigation: AppNavigationStack
    let connectivity: MockConnectivity
    let coordinator: AccountDeletionCoordinator
    let live: RecordingLiveActivity
    let base: URL
    let defaults: UserDefaults
}

@MainActor
func makeAccountDeletionHarness(connected: Bool = true) -> AccountDeletionHarness {
    let pieces = makeAccountDeletionBasePieces()
    let store = LocalStore()
    let connectivity = MockConnectivity(connected: connected)
    let syncController = SyncController(
        store: store,
        remote: MockCatalogRepository(),
        connectivity: connectivity
    ) { [weak sessionStore = pieces.sessionStore] in
        guard case let .signedIn(session) = sessionStore?.state else { return nil }
        return session.id
    }
    let live = RecordingLiveActivity()
    let timerService = TimerService(store: store, liveActivities: live)
    let navigation = AppNavigationStack()
    let authService = AuthService(
        repository: pieces.repo, keychain: pieces.keychain,
        cache: pieces.cache, sessionStore: pieces.sessionStore
    )
    let coordinator = AccountDeletionCoordinator(
        repository: pieces.repo,
        deletionStorage: AccountDeletionStorage(keychain: pieces.keychain),
        keychain: pieces.keychain,
        sessionStore: pieces.sessionStore,
        cache: pieces.cache,
        syncController: syncController,
        localStore: store,
        timerService: timerService,
        navigation: navigation,
        connectivity: connectivity,
        appleService: AppleSignInService(),
        authService: authService,
        markerResolver: ActiveAccountFileResolver(sessionDefaults: pieces.defaults),
        monitorMinInterval: 0,
        fileBaseURL: pieces.base
    )
    return AccountDeletionHarness(
        repo: pieces.repo, keychain: pieces.keychain, cache: pieces.cache,
        sessionStore: pieces.sessionStore, syncController: syncController,
        store: store, timerService: timerService, navigation: navigation,
        connectivity: connectivity, coordinator: coordinator,
        live: live, base: pieces.base, defaults: pieces.defaults
    )
}

@MainActor
private func makeAccountDeletionBasePieces() -> (
    repo: FakeAuthRepository,
    keychain: InMemoryKeychainStore,
    defaults: UserDefaults,
    base: URL,
    cache: SessionCache,
    sessionStore: SessionStore
) {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return (
        repo: FakeAuthRepository(),
        keychain: InMemoryKeychainStore(),
        defaults: defaults,
        base: base,
        cache: SessionCache(
            defaults: defaults,
            sessionFileURL: base.appendingPathComponent("active-session-user-id")
        ),
        sessionStore: SessionStore()
    )
}

@MainActor
func signInAccountDeletion(_ h: AccountDeletionHarness, accountID: String, email: String = "a@b.com") {
    h.sessionStore.setSignedIn(CachedSession(id: accountID, email: email, emailVerified: true))
    h.cache.save(CachedSession(id: accountID, email: email, emailVerified: true))
}

@MainActor
func seedAccountDeletionEvidence(
    _ h: AccountDeletionHarness,
    accountID: String,
    credential: String = "status-cap"
) async {
    let storage = AccountDeletionStorage(keychain: h.keychain)
    let result = await storage.saveStatusCredential(
        credential, expiresAt: "2099-01-01T00:00:00Z", accountID: accountID
    )
    guard case .success = result else {
        Issue.record("evidence seed failed")
        return
    }
}

@MainActor
func accountDeletionFile(_ h: AccountDeletionHarness, _ accountID: String) -> URL {
    LocalStore.databaseURL(userID: accountID, in: h.base)
}

@MainActor
func createAccountDeletionFile(_ h: AccountDeletionHarness, _ accountID: String) throws {
    _ = try LocalStore(url: accountDeletionFile(h, accountID), userID: accountID)
}
