#if DEBUG
// swiftlint:disable file_length
import Foundation
import os
import SwiftUI

/// DEBUG-only composition root for the UI-feedback loop.
///
/// The app is launched with `UITEST_SCREEN=<screen>` (see `TimeOfLifeApp`),
/// which routes here instead of `.production()`. This factory wires a stub
/// backend and seeds `SessionStore` + `AppNavigationStack` so the agent can
/// inspect any screen deterministically — no real network, no email, no OTP.
///
/// Never ships: the whole file is `#if DEBUG`. Release builds call
/// `.production()` only.
extension AppContainer {
    /// Seed diagnostics (Console): DEBUG-only fixture, never ships with the
    /// Release graph. Same `os.Logger` pattern as `SyncController`.
    private static let seedLogger = Logger(subsystem: "com.antonkosenko.timeoflifeapp", category: "uitest")

    /// Builds the deterministic UI-testing graph and seeds it to `screen`.
    static func uiTesting(screen: String) -> AppContainer {
        let keychain = InMemoryKeychainStore()
        let sessionCache = SessionCache()
        let sessionStore = SessionStore()
        let navigation = AppNavigationStack()
        let connectivity = MockConnectivity(connected: true)
        // The UI-testing graph pins a per-user test file (account-bound-store
        // spec shape): `lifio_<userId>.db` under a throwaway temp directory,
        // opened already bound so every screen reads one account's data. A
        // file failure must never crash the loop: fall back to an unbound
        // store (screens render empty) instead of `try!`.
        let localStore = (try? LocalStore(
            url: temporaryStoreURL(userID: "ui-test"),
            userID: "ui-test"
        )) ?? LocalStore()
        let timerService = TimerService(store: localStore)
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
            timerService: timerService,
            localStore: localStore,
            undoBuffer: undoBuffer,
            syncController: syncController,
            clientHolder: nil
        )

        seedAll(
            screen: screen, keychain: keychain, sessionStore: sessionStore,
            navigation: navigation, localStore: localStore
        )
        return container
    }

    /// Enqueues every deterministic seed for the requested screen.
    private static func seedAll(
        screen: String,
        keychain: InMemoryKeychainStore,
        sessionStore: SessionStore,
        navigation: AppNavigationStack,
        localStore: LocalStore
    ) {
        seed(screen: screen, sessionStore: sessionStore, navigation: navigation)
        seedHistoryIfNeeded(screen: screen, localStore: localStore)
        seedTrackCategoriesIfNeeded(screen: screen, localStore: localStore)
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
        case "trackCategories":
            // Deterministic running-track fixture: the shell opens on Track
            // with a running draft (see `seedTrackCategoriesIfNeeded`).
            sessionStore.setSignedIn(CachedSession(
                id: "ui-test", email: "user@example.com", emailVerified: true
            ))
            navigation.path = []
        case "history":
            // History with committed entries across twelve day groups
            // (repro/spike/scroll harness, 264 entries): the shell opens on
            // Track and the loop taps the History tab. Entries carry no
            // categories (fallback icon rows) — the headers, totals, and
            // scroll behavior are what is inspected.
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
        let apiClient = APIClient(baseURL: AppConfig.baseURL, session: .shared)
        let catalog = RemoteCatalogRepository(client: apiClient)
        return SyncController(
            store: store,
            remote: catalog,
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
    /// Kicks off History entry seeding for the `"history"` screen.
    /// The seeding task is enqueued at init, ahead of any appear-driven
    /// read (best-effort ordering, not a runtime guarantee: a read that
    /// interleaves mid-seed would see a partial list; History's
    /// appear/disappear reloads cover that).
    private static func seedHistoryIfNeeded(screen: String, localStore: LocalStore) {
        guard screen == "history" else { return }
        Task { await seedHistoryEntries(into: localStore) }
    }

    /// Kicks off the deterministic running-track fixture for the
    /// `"trackCategories"` screen. Enqueued at init, ahead of Track's first
    /// snapshot read (best-effort ordering, same caveat as History: Track's
    /// appear reload converges a mid-seed interleave). Uses `LocalStore`
    /// APIs exclusively — no raw SQLite writes. The `+Add` chip is rendered
    /// by the UI itself, so it is not seeded as a category.
    private static func seedTrackCategoriesIfNeeded(screen: String, localStore: LocalStore) {
        guard screen == "trackCategories" else { return }
        Task { await seedTrackCategories(into: localStore) }
    }

    /// Seeds the eleven fixture categories plus the running draft
    /// `Работа над приложением` with ordered selection Work-then-Sport.
    /// Idempotent: `createCategory(_:)` is a no-op replay on `id`, so the
    /// categories converge to the same set on relaunch. The draft upserts
    /// the singleton row, but a replay preserves the existing `startedAt`
    /// (the first seed pins it) so the running timer does not drift.
    private static func seedTrackCategories(into store: LocalStore) async {
        let fixtures: [(id: String, name: String, icon: String)] = [
            ("uitest-cat-work", "Work", "briefcase"),
            ("uitest-cat-sport", "Sport", "figure.run"),
            ("uitest-cat-education", "Education", "book"),
            ("uitest-cat-entertainment", "Entertainment", "tv"),
            ("uitest-cat-hobby", "Hobby", "paintbrush"),
            ("uitest-cat-relax", "Relax", "cup.and.saucer"),
            ("uitest-cat-sleep", "Sleep", "bed.double"),
            ("uitest-cat-home", "Домашние дела", "house"),
            ("uitest-cat-food", "Еда и готовка", "fork.knife"),
            ("uitest-cat-selfcare", "Забота о себе", "brain.head.profile"),
            ("uitest-cat-zoo", "Зоопарк", "pawprint"),
        ]
        for fixture in fixtures {
            do {
                try await store.createCategory(Category(
                    id: fixture.id,
                    name: fixture.name,
                    icon: fixture.icon
                ))
            } catch {
                seedLogger.error("UITest seed: createCategory failed id=\(fixture.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        let existingStartedAt: Date?
        do {
            existingStartedAt = try await store.timerDraft()?.startedAt ?? nil
        } catch {
            seedLogger.error("UITest seed: timerDraft read failed: \(error.localizedDescription, privacy: .public)")
            existingStartedAt = nil
        }
        do {
            try await store.saveTimerDraft(
                activityText: "Работа над приложением",
                categoryIDs: [workID(into: store), sportID(into: store)],
                startedAt: existingStartedAt ?? Date(),
                notes: ""
            )
        } catch {
            seedLogger.error("UITest seed: saveTimerDraft failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Resolves the fixture's selected ids by name: the launch gate seeds
    /// the 7 starter categories before the shell reveals, racing this task
    /// — whichever side wins a contested name, the lookup lands on the same
    /// name+icon row either way, so the draft selection always resolves.
    private static func workID(into store: LocalStore) async -> String {
        (try? await store.category(named: "Work")?.id) ?? "uitest-cat-work"
    }

    private static func sportID(into store: LocalStore) async -> String {
        (try? await store.category(named: "Sport")?.id) ?? "uitest-cat-sport"
    }

    /// Seeds committed entries across twelve calendar days (today back
    /// eleven days) for the History repro/spike/scroll harness: 22 entries
    /// per day, 264 total. Deterministic relative to `now` so day labels
    /// always read Today / Yesterday / absolute. A couple of long activity
    /// texts exercise row wrapping. Failures are ignored: the harness
    /// degrades to an empty History rather than crashing the loop.
    /// Re-running against an already-seeded store is a no-op in effect
    /// (`createEntry` is idempotent on `id`: a replay returns the existing
    /// record and adds no outbox row). Silently ignored here are its
    /// non-throwing `.invalid`/`.failure` results, matching the degrade-to-
    /// empty policy above.
    private static func seedHistoryEntries(into store: LocalStore) async {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let texts = [
            "Morning run", "Deep work", "Code review", "Lunch break",
            "Design sync", "Inbox zero", "Gym session", "Reading",
            "Side project", "Evening walk",
            "Quarterly planning workshop with the platform team",
            "Dentist appointment and pharmacy pickup afterwards",
        ]
        let days = 12
        let perDay = 22
        for dayIndex in 0..<days {
            let dayStart = calendar.date(
                byAdding: .day, value: -dayIndex, to: todayStart
            )!
            for i in 0..<perDay {
                // 00:05 + hourly slots: the last start (21:05) plus the
                // longest duration (89m) still ends before midnight.
                let start = calendar.date(
                    byAdding: .minute,
                    value: 5 + i * 60,
                    to: dayStart
                )!
                let minutes = 20 + (i * 17 + dayIndex * 7) % 70
                let entry = TimeEntry(
                    id: "uitest-h-\(dayIndex)-\(i)",
                    activityText: texts[(i + dayIndex * 5) % texts.count],
                    startedAt: start,
                    endedAt: calendar.date(byAdding: .minute, value: minutes, to: start),
                    durationSeconds: minutes * 60
                )
                _ = try? await store.createEntry(entry)
            }
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
