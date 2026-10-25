import Testing
import Foundation
@testable import Shunik

// swiftlint:disable:next todo
// SHUNIK-TODO: pet-care preload assertions will hook in here.
/// Scaffold sign-in lifecycle: `RootView.beginSignIn` reveals only after
/// `prepareAccountStore` (open → commit) succeeds, and activates sync after
/// the cancellation/session guards.
@MainActor
@Suite("SignInLifecycle")
struct SignInLifecycleTests {

    @Test("prepare binds a fresh account before reveal")
    func prepareBindsFreshAccount() async throws {
        let householdID = uniqueHouseholdID()
        let container = makeContainer(householdID: householdID)
        defer { removeHouseholdFile(householdID: householdID) }

        let ready = await container.prepareAccountStore(userID: "user-bind-1")

        #expect(ready)
        #expect(container.localStoreOpenError == nil)
        #expect(await container.localStore.boundHouseholdID == householdID)
    }

    @Test("prepare reports failure without revealing when offline with no cache")
    func prepareInvalidUserReportsWithoutRevealing() async {
        let container = makeContainer(householdID: nil)

        let ready = await container.prepareAccountStore(userID: "user-offline-" + UUID().uuidString)

        #expect(!ready, "no reveal on failed prepare")
        #expect(container.localStoreOpenError != nil)
        #expect(await container.localStore.boundHouseholdID == nil)
    }

    @Test("prepare never activates sync (activation stays a post-reveal decision)")
    func prepareLeavesSyncInactive() async {
        // Pins that preparation itself never touches sync: open/commit are
        // local-file-only work, so `prepareAccountStore` cannot leave a
        // cycle in flight even if the caller is cancelled mid-prepare. The
        // sign-out-mid-prepare guards are view-layer (`RootView.beginSignIn`)
        // and are not exercised by this unit test.
        let householdID = uniqueHouseholdID()
        let container = makeContainer(householdID: householdID)
        defer { removeHouseholdFile(householdID: householdID) }

        _ = await container.prepareAccountStore(userID: "user-idle-1")

        #expect(container.syncController.status == .inactive)
        #expect(!container.syncController.isCycleLive)
    }

    // MARK: - Helpers

    private func uniqueHouseholdID() -> String { "sl-" + UUID().uuidString.lowercased() }

    private func removeHouseholdFile(householdID: String) {
        let url = LocalStore.databaseURL(householdID: householdID)
        try? FileManager.default.removeItem(at: url)
        for ext in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ext))
        }
    }

    private func makeContainer(householdID: String? = "sl-test-household") -> AppContainer {
        let url = URL(string: "https://example.com")!
        let repository = FakeAuthRepository()
        let keychain = InMemoryKeychainStore()
        let cache = SessionCache(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sessionStore = SessionStore()
        let localStore = LocalStore()
        let connectivity = MockConnectivity(connected: true)
        let authService = AuthService(
            repository: repository, keychain: keychain, cache: cache, sessionStore: sessionStore
        )
        return AppContainer(
            baseURL: url,
            apiClient: APIClient(baseURL: url, session: .shared),
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
            ) { nil },
            householdService: HouseholdService(
                relay: scriptedRelay(householdID: householdID),
                defaults: UserDefaults(suiteName: UUID().uuidString),
                sidecarURL: nil
            )
        )
    }

    private func scriptedRelay(householdID: String?) -> TestHouseholdRelay {
        let relay = TestHouseholdRelay()
        if let householdID {
            relay.household = HouseholdWithMembers(
                household: HouseholdRecord(
                    id: householdID, createdAt: "2026-01-01T00:00:00.000Z",
                    updatedAt: "2026-01-01T00:00:00.000Z", updatedBy: "user-1"
                ),
                members: []
            )
        } else {
            relay.fetchError = APIError.offline
        }
        return relay
    }
}
