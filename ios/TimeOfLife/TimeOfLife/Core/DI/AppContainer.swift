import Foundation
import OSLog
import SwiftUI

import LifioLiveActivityCore

/// Composition root. Builds the real production graph and exposes the
/// objects views/view models need. Everything is injectable for tests.
///
/// The local store is account-bound (account-bound-store spec): it starts
/// UNBOUND and binds to the signed-in account's `lifio_<userId>.db` file.
/// `TimerService`, `UndoBufferStore`, and `SyncController` all hold the same
/// `LocalStore` actor instance, so every view/feature resolves the ACTIVE
/// account's data through `container.localStore` — the accessor shape is
/// stable across account changes (no service-graph rebuild needed).
@MainActor
final class AppContainer: ObservableObject {
    private let baseURL: URL
    private let apiClient: APIClient
    private let keychain: KeychainStoring
    private let sessionCache: SessionCache
    private let repository: AuthRepository
    let sessionStore: SessionStore
    let navigation: AppNavigationStack
    let connectivity: Connectivity
    let authService: AuthService
    let appleService: AppleSignInService
    let timerService: TimerService
    /// Owns the account-deletion lifecycle (submit, status resolution,
    /// scoped cleanup). Wired with the same graph pieces as everything else.
    let deletionCoordinator: AccountDeletionCoordinator
    /// The active account's local store. UNBOUND until `openLocalStore()`
    /// runs on sign-in/restored session; before that every tracker operation
    /// fails with `LocalStore.LocalStoreError.notBound`.
    let localStore: LocalStore
    let undoBuffer: UndoBufferStore
    let syncController: SyncController
    /// The last `openLocalStore` failure (disk-full, corrupt file, migration
    /// error — and, as of the complexity-reduction pass, integrity failures
    /// too: an `invalidUserID`/`accountMismatch` bind leaves the store
    /// cleanly unbound and surfaces here instead of crashing on sign-in; the
    /// gate stays up with the error and the next sign-in retries the bind).
    /// `openLocalStore` stays non-throwing because `RootView` awaits it
    /// inline during startup.
    @Published var localStoreOpenError: Error?
    /// Strong reference to the holder that wires the API client's refresh hook
    /// back to `authService`. If this were not retained, the holder would
    /// deallocate after `production()` returns and token refresh would fail.
    private let clientHolder: APIClientHolder?

    private static let logger = Logger(subsystem: "com.antonkosenko.timeoflifeapp", category: "store")

    init(
        baseURL: URL,
        apiClient: APIClient,
        keychain: KeychainStoring,
        sessionCache: SessionCache,
        repository: AuthRepository,
        sessionStore: SessionStore,
        navigation: AppNavigationStack,
        connectivity: Connectivity,
        authService: AuthService,
        appleService: AppleSignInService,
        timerService: TimerService,
        localStore: LocalStore,
        undoBuffer: UndoBufferStore,
        syncController: SyncController,
        clientHolder: APIClientHolder? = nil,
        deletionCoordinator: AccountDeletionCoordinator? = nil
    ) {
        self.baseURL = baseURL
        self.apiClient = apiClient
        self.keychain = keychain
        self.sessionCache = sessionCache
        self.repository = repository
        self.sessionStore = sessionStore
        self.navigation = navigation
        self.connectivity = connectivity
        self.authService = authService
        self.appleService = appleService
        self.timerService = timerService
        self.localStore = localStore
        self.undoBuffer = undoBuffer
        self.syncController = syncController
        self.clientHolder = clientHolder
        self.deletionCoordinator = deletionCoordinator ?? AccountDeletionCoordinator(
            repository: repository,
            deletionStorage: authService.deletionStorage,
            keychain: keychain,
            sessionStore: sessionStore,
            cache: sessionCache,
            syncController: syncController,
            localStore: localStore,
            timerService: timerService,
            navigation: navigation,
            connectivity: connectivity,
            appleService: appleService,
            authService: authService
        )
        registerReapCheck()
        observeExternalStopSignal()
    }

    /// Handles an Island Stop: reaps activities orphaned by the intent and
    /// tells tracker surfaces to reload (the intent already saved the entry
    /// and cleared the draft — Track/compact would otherwise keep ticking
    /// stale in-memory state). The run is definitively over, so the
    /// background reap chain is cancelled — unless a new run started in
    /// the meantime (its Start re-armed the chain; cancelling here would
    /// strand it), so the cancel is draft-gated.
    func handleExternalStop() {
        Task {
            await timerService.endOrphanedActivities()
            if (try? await timerService.runningTimerDraft()) == nil {
                BackgroundReapScheduler.cancelReapCheck()
            }
            NotificationCenter.default.post(name: .timerStoppedExternally, object: nil)
        }
    }

    /// Registers the background reap check (live-activities BG chain): a
    /// background launch runs `AppContainer.init` too, so registering here
    /// covers both foreground and background launches. The handler runs
    /// the orphan-reap funnel (which resolves Saved-vs-silent itself) and
    /// re-arms only while a draft is still live — a finished run ends the
    /// chain, and the next Start re-arms it.
    private func registerReapCheck() {
        BackgroundReapScheduler.register { [weak self] in
            guard let self else { return false }
            await self.timerService.endOrphanedActivities()
            // Fail-open toward re-arming: an unreadable store must not drop
            // the chain (the funnel itself already failed closed by ending
            // nothing), or a transient DB error would strand a live banner.
            let draft: RunningTimerDraft?
            do {
                draft = try await self.timerService.runningTimerDraft()
            } catch {
                return true
            }
            return draft != nil
        }
    }

    /// Observes the Darwin signal posted by the Stop intent (live-activities
    /// D8). The C callback hops to the actor; the box lives as long as the
    /// container (app lifetime) by design.
    private func observeExternalStopSignal() {
        final class HandlerBox: Sendable {
            let onSignal: @Sendable () -> Void
            init(_ onSignal: @escaping @Sendable () -> Void) {
                self.onSignal = onSignal
            }
        }
        let box = HandlerBox { [weak self] in
            Task { await self?.handleExternalStop() }
        }
        let context = Unmanaged.passRetained(box).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            context,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let box = Unmanaged<HandlerBox>.fromOpaque(observer).takeUnretainedValue()
                box.onSignal()
            } as CFNotificationCallback,
            LiveActivitySignal.name as CFString,
            nil,
            .deliverImmediately
        )
    }

    /// Default production graph wired against `AppConfig.baseURL`. The local
    /// store is built unbound; call `openLocalStore(userID:)` once the
    /// session resolves (restore on launch, verify/apple on login) and
    /// `closeLocalStore()` on sign-out — account-bound-store spec.
    static func production() -> AppContainer {
        let baseURL = AppConfig.baseURL
        let keychain = KeychainStore()
        // The cache must write the session id to the App Group defaults —
        // the same store `ActiveAccountFileResolver` reads (lock-screen-
        // controls delta 4.2), or resolve() sees `.locked` for real sessions.
        // The id is additionally mirrored to the group-container sidecar
        // file, which is what extension processes actually read (suite
        // UserDefaults detach from cfprefsd in extensions).
        let sessionCache = SessionCache(
            defaults: UserDefaults(suiteName: LocalStore.appGroupID) ?? .standard,
            sessionFileURL: ActiveAccountFileResolver.sessionFileURL()
        )
        let sessionStore = SessionStore()
        let navigation = AppNavigationStack()
        let connectivity = NetworkMonitor()
        let localStore = LocalStore()
        let timerService = TimerService(store: localStore)

        let (client, clientHolder) = makeAuthClient(baseURL: baseURL, keychain: keychain)
        let repository = RemoteAuthRepository(client: client)
        let authService = AuthService(
            repository: repository,
            keychain: keychain,
            cache: sessionCache,
            sessionStore: sessionStore
        )
        clientHolder.service = authService

        let appleService = AppleSignInService()
        let catalog = RemoteCatalogRepository(client: client)
        let undoBuffer = UndoBufferStore(store: localStore)
        let syncController = SyncController(
            store: localStore,
            remote: catalog,
            connectivity: connectivity
        ) { [weak sessionStore] in
            // The same-account guard reads the session user at guard time:
            // the session's `userId` must match the account `activate()`
            // bound, or the cycle is refused/aborted (sync-client spec).
            guard case let .signedIn(session) = sessionStore?.state else { return nil }
            return session.id
        }

        return AppContainer(
            baseURL: baseURL,
            apiClient: client,
            keychain: keychain,
            sessionCache: sessionCache,
            repository: repository,
            sessionStore: sessionStore,
            navigation: navigation,
            connectivity: connectivity,
            authService: authService,
            appleService: appleService,
            timerService: timerService,
            localStore: localStore,
            undoBuffer: undoBuffer,
            syncController: syncController,
            clientHolder: clientHolder
        )
    }

    // MARK: - Account-bound store lifecycle (account-bound-store spec)

    /// Binds the local store to the signed-in account: opens (creating if
    /// needed) `lifio_<userId>.db` in the App Group. Called by the signed-in
    /// path in `RootView` — restore-on-launch and both sign-in flows — and
    /// awaited before any store operation (undo commitAll, seeding, first
    /// sync cycle) touches the file.
    ///
    /// Every failure (integrity or retryable) is logged and surfaced via
    /// `localStoreOpenError` instead of crashing on sign-in: the store stays
    /// cleanly unbound and the gate stays up with the error.
    ///
    /// Returns whether the store is bound afterwards. The caller (`RootView`
    /// `beginSignIn`) MUST check this: a failed open leaves the store cleanly
    /// unbound, so mounting the shell on `false` would run every tracker read
    /// against `notBound`. The error is cleared on entry so a retry never sees
    /// a stale failure.
    @discardableResult
    func openLocalStore(userID: String) async -> Bool {
        localStoreOpenError = nil
        do {
            try await localStore.openAccount(userID: userID)
            return true
        } catch {
            localStoreOpenError = error
            Self.logger.error("LocalStore account binding failed: \(String(describing: error), privacy: .public)")
            // Sync-distress breadcrumb (observability Stage 0): fixed
            // string only — the error can carry file paths.
            SentryReporter.addSyncDistressBreadcrumb("local store open failed")
            return false
        }
    }

    /// Closes the active account file and keeps it on disk (logout keeps all
    /// files: dirty outbox + running timer draft stay in the dormant file).
    /// Called on the signed-out path in `RootView`.
    func closeLocalStore() async {
        await localStore.closeAccount()
    }

    /// Prepares the account's local store for shell reveal
    /// (fix-track-empty-after-reinstall): opens the account file, commits
    /// deletions buffered by the previous process, then seeds the starter
    /// categories — all BEFORE the caller reveals the shell, so the first
    /// Track paint already carries the seed and never flashes an empty
    /// store. Sync activation stays with the caller (background, post-reveal).
    ///
    /// Returns whether the store is bound AND seeded. The caller (`RootView`
    /// `beginSignIn`) MUST check this and must not reveal on `false`: the
    /// gate stays up with `localStoreOpenError` (same branch as a failed
    /// bind, with the same sign-out escape) and the next sign-in retries.
    /// `seedNames` defaults to the localized starter set; tests inject a
    /// short array to drive the seed-failure path.
    @discardableResult
    func prepareAccountStore(
        userID: String,
        seedNames: [String] = String.starterCategoryNames
    ) async -> Bool {
        let opened = await openLocalStore(userID: userID)
        guard opened else { return false }
        // Best-effort like before: a commit failure must not block reveal —
        // the buffer retries on the next launch.
        try? await undoBuffer.commitAll()
        do {
            _ = try await localStore.seedStarterCategoriesIfNeeded(names: seedNames)
        } catch {
            localStoreOpenError = error
            Self.logger.error("LocalStore starter seeding failed: \(String(describing: error), privacy: .public)")
            return false
        }
        return true
    }

    /// Deletes ONLY the active account's database file (explicit per-account
    /// Erase in Profile; never a side effect of logout/switch/revoke). The
    /// store ends unbound; the caller clears the session artifacts. Throwing:
    /// a failed file removal propagates so the UI can report it instead of
    /// claiming success.
    func eraseLocalData() async throws {
        try await localStore.eraseAll()
    }

    /// Builds the API client and the back-reference holder used to break the
    /// auth-service / API-client initialization cycle. Kept separate so the
    /// production factory stays within the linter's function-body limit.
    private static func makeAuthClient(
        baseURL: URL,
        keychain: KeychainStoring
    ) -> (APIClient, APIClientHolder) {
        let clientHolder = APIClientHolder()
        let deviceIdentity = DeviceIdentityStore(keychain: keychain)
        let client = APIClient(
            baseURL: baseURL,
            session: URLSession.shared,
            accessTokenProvider: { [weak keychain] () async -> String? in
                // Tokens live in the single credential snapshot now (split
                // per-token Keychain keys are gone): an unreadable store
                // yields no token, and the refresh path keeps retry intent.
                guard let result = await keychain?.loadSnapshot(),
                      case .success(let snapshot) = result
                else { return nil }
                return snapshot?.accessToken
            },
            refreshHandler: { [weak clientHolder] () async throws -> String in
                guard let service = await clientHolder?.service else {
                    throw APIError.unauthorized
                }
                return try await service.performRefresh()
            },
            // Every session-carrying auth request must carry `X-Device-Id`
            // (device-sessions spec); the backend rejects requests without it.
            deviceIdProvider: { [deviceIdentity] () async -> String in
                await deviceIdentity.current()
            }
        )
        return (client, clientHolder)
    }
}

/// Holds a back-reference so the `APIClient`'s refresh closure can reach the
/// `AuthService` once it's constructed (breaks the init cycle).
@MainActor
final class APIClientHolder {
    weak var service: AuthService?
    init() {}
}

extension Notification.Name {
    /// Posted (in-process) after an Island Stop is handled: tracker surfaces
    /// reload so no stale running state survives (live-activities D8).
    static let timerStoppedExternally = Notification.Name("timerStoppedExternally")
}
