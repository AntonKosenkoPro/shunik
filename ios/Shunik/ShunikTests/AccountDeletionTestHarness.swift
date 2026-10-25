import Testing
import Foundation
@testable import Shunik

/// Shared harness for the account-deletion coordinator suites: fake network,
/// in-memory Keychain, isolated session cache with a throwaway sidecar,
/// and a throwaway file base so scoped erasure is asserted against real
/// files without touching other tests.
@MainActor
struct AccountDeletionHarness {
    let repo: FakeAuthRepository
    let keychain: InMemoryKeychainStore
    let cache: SessionCache
    let sessionStore: SessionStore
    let syncController: SyncController
    let store: LocalStore
    let navigation: AppNavigationStack
    let connectivity: MockConnectivity
    let coordinator: AccountDeletionCoordinator
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
        connectivity: connectivity
    ) { [weak sessionStore = pieces.sessionStore] in
        guard case let .signedIn(session) = sessionStore?.state else { return nil }
        return session.id
    }
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
        store: store, navigation: navigation,
        connectivity: connectivity, coordinator: coordinator,
        base: pieces.base, defaults: pieces.defaults
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
    // Household-active marker (mirrors `HouseholdService.resolveHousehold`):
    // the coordinator erases exactly the file this selects.
    h.defaults.set(accountID, forKey: "com.shunik.session.householdID")
    try? accountID.write(
        to: h.base.appendingPathComponent(ActiveAccountFileResolver.householdSessionFileName),
        atomically: true,
        encoding: .utf8
    )
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
    LocalStore.databaseURL(householdID: accountID, in: h.base)
}

@MainActor
func createAccountDeletionFile(_ h: AccountDeletionHarness, _ accountID: String) throws {
    _ = try LocalStore(url: accountDeletionFile(h, accountID), householdID: accountID)
}
