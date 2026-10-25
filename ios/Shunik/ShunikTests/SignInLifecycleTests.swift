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
        let container = makeContainer()
        let userID = uniqueUserID()
        defer { removeAccountFile(userID: userID) }

        let ready = await container.prepareAccountStore(userID: userID)

        #expect(ready)
        #expect(container.localStoreOpenError == nil)
        #expect(await container.localStore.boundUserID == userID)
    }

    @Test("prepare reports failure without revealing on invalid user")
    func prepareInvalidUserReportsWithoutRevealing() async {
        let container = makeContainer()

        let ready = await container.prepareAccountStore(userID: "not valid!!")

        #expect(!ready, "no reveal on failed prepare")
        #expect(container.localStoreOpenError != nil)
        #expect(await container.localStore.boundUserID == nil)
    }

    @Test("prepare never activates sync (activation stays a post-reveal decision)")
    func prepareLeavesSyncInactive() async {
        // Pins that preparation itself never touches sync: open/commit are
        // local-file-only work, so `prepareAccountStore` cannot leave a
        // cycle in flight even if the caller is cancelled mid-prepare. The
        // sign-out-mid-prepare guards are view-layer (`RootView.beginSignIn`)
        // and are not exercised by this unit test.
        let container = makeContainer()
        let userID = uniqueUserID()
        defer { removeAccountFile(userID: userID) }

        _ = await container.prepareAccountStore(userID: userID)

        #expect(container.syncController.status == .inactive)
        #expect(!container.syncController.isCycleLive)
    }

    // MARK: - Helpers

    private func uniqueUserID() -> String { "sl-" + UUID().uuidString.lowercased() }

    private func removeAccountFile(userID: String) {
        let url = LocalStore.databaseURL(userID: userID)
        try? FileManager.default.removeItem(at: url)
        for ext in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ext))
        }
    }

    private func makeContainer() -> AppContainer {
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
            ) { nil }
        )
    }
}
