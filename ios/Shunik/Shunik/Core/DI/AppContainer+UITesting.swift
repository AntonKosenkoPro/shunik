#if DEBUG
import Foundation
import os
import SwiftUI

/// DEBUG-only composition root for the UI-feedback loop.
///
/// The app is launched with `UITEST_SCREEN=<screen>` (see `ShunikApp`),
/// which routes here instead of `.production()`. This factory wires a stub
/// backend and seeds `SessionStore` + `AppNavigationStack` so the agent can
/// inspect any screen deterministically — no real network, no email, no OTP.
///
/// Never ships: the whole file is `#if DEBUG`. Release builds call
/// `.production()` only.
extension AppContainer {
    /// Seed diagnostics (Console): DEBUG-only fixture, never ships with the
    /// Release graph. Same `os.Logger` pattern as `SyncController`.
    private static let seedLogger = Logger(subsystem: "com.antonkosenko.shunik", category: "uitest")

    /// Builds the deterministic UI-testing graph and seeds it to `screen`.
    static func uiTesting(screen: String) -> AppContainer {
        let keychain = InMemoryKeychainStore()
        let sessionCache = SessionCache()
        let sessionStore = SessionStore()
        let navigation = AppNavigationStack()
        let connectivity = MockConnectivity(connected: true)
        // The UI-testing graph pins a per-user test file (account-bound-store
        // spec shape): `shunik_<userId>.db` under a throwaway temp directory,
        // opened already bound so every screen reads one account's data. A
        // file failure must never crash the loop: fall back to an unbound
        // store (screens render empty) instead of `try!`.
        let localStore = (try? LocalStore(
            url: temporaryStoreURL(userID: "ui-test"),
            userID: "ui-test"
        )) ?? LocalStore()
        let repository = UITestingAuthRepository()
        let authService = AuthService(
            repository: repository,
            keychain: keychain,
            cache: sessionCache,
            sessionStore: sessionStore
        )
        // An `APIClient` is required by the container but is never called in
        // this graph (the stub repository answers everything), so wire it
        // with no token/refresh/device-id hooks against the configured base
        // URL — the UI-testing stub never hits the real auth API.
        let apiClient = APIClient(baseURL: AppConfig.baseURL, session: .shared)
        let appleService = AppleSignInService()
        let undoBuffer = UndoBufferStore(store: localStore)
        let syncController = makeStubSyncController(
            store: localStore, connectivity: connectivity, sessionStore: sessionStore
        )

        let container = AppContainer(
            baseURL: AppConfig.baseURL,
            apiClient: apiClient,
            keychain: keychain,
            sessionCache: sessionCache,
            repository: repository,
            sessionStore: sessionStore,
            navigation: navigation,
            connectivity: connectivity,
            authService: authService,
            appleService: appleService,
            localStore: localStore,
            undoBuffer: undoBuffer,
            syncController: syncController,
            clientHolder: nil
        )

        seedAll(
            screen: screen, keychain: keychain, sessionStore: sessionStore,
            navigation: navigation
        )
        return container
    }

    /// Enqueues every deterministic seed for the requested screen.
    private static func seedAll(
        screen: String,
        keychain: InMemoryKeychainStore,
        sessionStore: SessionStore,
        navigation: AppNavigationStack
    ) {
        seed(screen: screen, sessionStore: sessionStore, navigation: navigation)
        seedDeletionEvidence(keychain: keychain)
    }

    private static func temporaryStoreURL(userID: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(LocalStore.databaseFileName(userID: userID))
    }

    /// Places the app on a specific screen for inspection.
    private static func seed(
        screen: String,
        sessionStore: SessionStore,
        navigation: AppNavigationStack
    ) {
        // The stub graph never resolves the restore before the first frame:
        // clear the flag so `RootView` starts on gated content, not the
        // splash. NOTE: `RootView.task` still runs `restoreSession()`, which
        // re-latches `isRestoring = true` for one actor hop before its defer
        // clears it — a transient splash frame can still appear over stub
        // screens; gate the restore in the stub path if that matters.
        sessionStore.setRestoring(false)
        switch screen {
        case "emailEntry":
            // Auth flow pushed to the email entry screen.
            sessionStore.setSignedOut()
            navigation.path = [.emailEntry]
        case "otpEntry":
            // Auth flow pushed to the OTP screen.
            sessionStore.setSignedOut()
            navigation.path = [.otpEntry(email: "user@example.com")]
        case "signedIn":
            // `RootView` renders the app shell (Track) when the session is signed in.
            sessionStore.setSignedIn(CachedSession(
                id: "ui-test", email: "user@example.com", emailVerified: true
            ))
            navigation.path = []
        case "trackCategories", "history":
            // swiftlint:disable:next todo
            // SHUNIK-TODO: scaffold — these screens are gone; mount the
            // signed-in shell (Profile) until pet-care screens exist.
            sessionStore.setSignedIn(CachedSession(
                id: "ui-test", email: "user@example.com", emailVerified: true
            ))
            navigation.path = []
        default:
            // "welcome" (and any unknown value) → auth-flow root.
            sessionStore.setSignedOut()
            navigation.path = []
        }
    }

    /// Sync controller for the stub graph: same same-account guard shape as
    /// production, reading the stub session. Sync traffic never runs here
    /// (no test screen triggers it), but the wiring must exist for the
    /// container to build.
    private static func makeStubSyncController(
        store: LocalStore,
        connectivity: MockConnectivity,
        sessionStore: SessionStore
    ) -> SyncController {
        SyncController(
            store: store,
            connectivity: connectivity
        ) { [weak sessionStore] in
            guard case let .signedIn(session) = sessionStore?.state else { return nil }
            return session.id
        }
    }
    /// Seeds a status-capability-like test value into this graph's SEPARATE
    /// (in-memory, DEBUG-only) Keychain — never the production Keychain. It
    /// enables the Account deletion flow in the harness without real
    /// network/OTP: no production bypass, no shared state. Best-effort: the
    /// stub `me()` below returns the same test value, so restore
    /// re-establishes it even if this seed races.
    private static func seedDeletionEvidence(keychain: InMemoryKeychainStore) {
        let deletionSeed = AccountDeletionStorage(keychain: keychain)
        Task {
            _ = await deletionSeed.saveStatusCredential(
                "status-test-ui-test",
                expiresAt: "2099-01-01T00:00:00Z",
                accountID: "ui-test"
            )
        }
    }
}

/// Stub `AuthRepository` for the UI-feedback loop. Returns deterministic,
/// canned sessions so the agent can drive the flow (request OTP → enter code
/// → verify) without a network or real email. DEBUG-only; never ships.
///
/// Deletion-aware: `fetchAccountStatus` reports `.active` until
/// `deleteAccount` is called, then flips to `.deleted` for the stub account
/// — so the harness can exercise Account → Cancel (no call, still active)
/// and the confirmed-delete path without real network/OTP/prod. No
/// production bypass: everything lives in this DEBUG graph's in-memory
/// Keychain and throwaway database file.
///
/// Locked for thread safety (the stub is held across actor boundaries).
final class UITestingAuthRepository: AuthRepository, @unchecked Sendable {
    private static let user = UserDTO(
        id: "ui-test", email: "user@example.com", emailVerified: true
    )
    /// Test status-capability value, matching the seeded Keychain entry in
    /// `uiTesting(screen:)`. Far-future expiry so harness checks stay valid.
    static let testStatusCredential = "status-test-ui-test"
    private static let testStatusExpiresAt = "2099-01-01T00:00:00Z"

    private let lock = NSLock()
    private var deleted = false

    private static func session(for email: String) -> AuthSession {
        AuthSession(
            accessToken: "at-ui",
            refreshToken: "rt-ui",
            user: UserDTO(id: "ui-test", email: email, emailVerified: true),
            accountStatusCredential: testStatusCredential,
            accountStatusExpiresAt: testStatusExpiresAt
        )
    }

    /// Test observability: whether the stub account has been deleted.
    var isDeleted: Bool {
        lock.lock(); defer { lock.unlock() }
        return deleted
    }

    func requestOtp(email: String) async throws {}

    func verifyOtp(email: String, code: String) async throws -> AuthSession {
        Self.session(for: email)
    }

    func appleSignIn(identityToken: String, authorizationCode: String? = nil) async throws -> AuthSession {
        Self.session(for: "apple@privaterelay.appleid.com")
    }

    func refresh(refreshToken: String, attemptId: String) async throws -> AuthSession {
        Self.session(for: "user@example.com")
    }

    func logout() async throws {}

    func me() async throws -> MeResponse {
        MeResponse(
            user: Self.user,
            accountStatusCredential: Self.testStatusCredential,
            accountStatusExpiresAt: Self.testStatusExpiresAt
        )
    }

    func deleteAccount() async throws -> AccountDeletionOutcome {
        markDeleted()
        return .completed
    }

    func fetchAccountStatus(statusCredential: String) async throws -> AccountStatusResponse {
        AccountStatusResponse(accountID: "ui-test", state: isDeleted ? .deleted : .active)
    }

    func acquireAppleDeletionCredential(identityToken: String, authorizationCode: String?) async throws {}

    /// Synchronous lock dance (Swift 6 mode forbids direct `NSLock` use
    /// from async contexts — callers never touch the lock directly).
    private func markDeleted() {
        lock.lock(); deleted = true; lock.unlock()
    }
}
#endif
