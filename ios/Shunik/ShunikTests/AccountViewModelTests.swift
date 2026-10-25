import Testing
import Foundation
@testable import Shunik

/// Account page behavior (Account.md + account-deletion spec 7.2–7.7):
/// read-only cached email, confirmation-free sign-out, single-confirmation
/// local erase with server-untouched scope, and exactly one explicit
/// permanent-deletion alert with progress, duplicate protection, and
/// result-notice retry/cancel. A result notice is information, never a
/// second confirmation.
@MainActor
@Suite("Account view model", .serialized)
struct AccountViewModelTests {

    struct Harness {
        let container: AppContainer
        let repo: FakeAuthRepository
        let keychain: InMemoryKeychainStore
        let sessionStore: SessionStore
        let syncController: SyncController
        let base: URL
    }

    private func makeHarness(connected: Bool = true, preboundFile: URL? = nil) -> Harness {
        let repo = FakeAuthRepository()
        let keychain = InMemoryKeychainStore()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let cache = SessionCache(
            defaults: defaults,
            sessionFileURL: base.appendingPathComponent("active-session-user-id")
        )
        let sessionStore = SessionStore()
        let connectivity = MockConnectivity(connected: connected)
        let localStore: LocalStore
        if let preboundFile {
            // swiftlint:disable:next force_try
            localStore = try! LocalStore(url: preboundFile, userID: "u1")
        } else {
            localStore = LocalStore()
        }
        let syncController = SyncController(
            store: localStore,
            connectivity: connectivity
        ) { [weak sessionStore] in
            guard case let .signedIn(session) = sessionStore?.state else { return nil }
            return session.id
        }
        let container = AppContainer(
            baseURL: URL(string: "https://example.com")!,
            apiClient: APIClient(baseURL: URL(string: "https://example.com")!, session: .shared),
            keychain: keychain,
            sessionCache: cache,
            repository: repo,
            sessionStore: sessionStore,
            navigation: AppNavigationStack(),
            connectivity: connectivity,
            authService: AuthService(
                repository: repo, keychain: keychain, cache: cache, sessionStore: sessionStore
            ),
            appleService: AppleSignInService(),
            localStore: localStore,
            undoBuffer: UndoBufferStore(store: localStore),
            syncController: syncController
        )
        return Harness(
            container: container, repo: repo, keychain: keychain,
            sessionStore: sessionStore, syncController: syncController, base: base
        )
    }

    private func signIn(_ h: Harness, accountID: String = "u1", email: String = "user@example.com") {
        h.sessionStore.setSignedIn(CachedSession(id: accountID, email: email, emailVerified: true))
    }

    private func seedEvidence(_ h: Harness, accountID: String) async {
        let storage = AccountDeletionStorage(keychain: h.keychain)
        let result = await storage.saveStatusCredential(
            "status-cap", expiresAt: "2099-01-01T00:00:00Z", accountID: accountID
        )
        guard case .success = result else {
            Issue.record("evidence seed failed")
            return
        }
    }

    // MARK: - Email and sign-out

    @Test("email is the cached session address, read-only")
    func emailFromSession() {
        let h = makeHarness()
        signIn(h, email: "user@example.com")
        #expect(AccountViewModel(container: h.container).email == "user@example.com")
    }

    @Test("sign out is confirmation-free and keeps local files")
    func signOutKeepsFiles() async throws {
        let h = makeHarness()
        signIn(h, accountID: "u1")
        let url = LocalStore.databaseURL(userID: "u1", in: h.base)
        _ = try LocalStore(url: url, userID: "u1")
        #expect(FileManager.default.fileExists(atPath: url.path))

        await AccountViewModel(container: h.container).signOut()

        if case .signedOut = h.sessionStore.state {
        } else {
            Issue.record("expected signed out")
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(h.container.navigation.path.isEmpty)
    }

    // MARK: - Delete local data

    @Test("local erase removes only the active file and signs out")
    func eraseLocalDataFlow() async throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(LocalStore.databaseFileName(userID: "u1"))
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let h = makeHarness(preboundFile: file)
        signIn(h, accountID: "u1")
        #expect(FileManager.default.fileExists(atPath: file.path))

        await AccountViewModel(container: h.container).eraseLocalData()

        #expect(!FileManager.default.fileExists(atPath: file.path))
        if case .signedOut = h.sessionStore.state {
        } else {
            Issue.record("expected signed out after local erase")
        }
        #expect(h.container.navigation.path.isEmpty)
    }

    // MARK: - Permanent deletion

    @Test("204 delete signs out through the gate with no notice")
    func delete204SignsOut() async {
        let h = makeHarness()
        signIn(h, accountID: "u1")
        await seedEvidence(h, accountID: "u1")
        h.repo.deleteAccountResult = .completed

        let vm = AccountViewModel(container: h.container)
        await vm.confirmDelete()

        if case .signedOut = h.sessionStore.state {
        } else {
            Issue.record("expected signed out after confirmed deletion")
        }
        #expect(vm.deleteNotice == nil)
        #expect(vm.isDeleting == false)
    }

    @Test("offline delete explains the connection requirement")
    func deleteOfflineNotice() async {
        let h = makeHarness(connected: false)
        signIn(h, accountID: "u1")
        await seedEvidence(h, accountID: "u1")

        let vm = AccountViewModel(container: h.container)
        await vm.confirmDelete()

        #expect(vm.deleteNotice == .offline)
        if case .signedIn = h.sessionStore.state {
        } else {
            Issue.record("must stay signed in when offline")
        }
        #expect(!h.repo.calls.contains(.deleteAccount))
    }

    @Test("active verdict shows still-exists with retry and cancel")
    func activeVerdictStillExists() async {
        let h = makeHarness()
        signIn(h, accountID: "u1")
        await seedEvidence(h, accountID: "u1")
        h.repo.deleteAccountError = APIError.server(code: "http_500", message: "boom")
        h.repo.accountStatusResult = AccountStatusResponse(accountID: "u1", state: .active)

        let vm = AccountViewModel(container: h.container)
        await vm.confirmDelete()

        #expect(vm.deleteNotice == .stillExists)
        // Retry re-presents the same single alert; cancel clears the fence.
        vm.retryDelete()
        #expect(vm.isShowingDeleteConfirm)
        #expect(vm.deleteNotice == nil)
        vm.deleteNotice = .stillExists
        await vm.cancelPendingDeletion()
        #expect(vm.deleteNotice == nil)
        #expect(!h.syncController.isDeletionFenced(userID: "u1"))
    }

    @Test("ambiguous with inconclusive status shows the failure notice")
    func ambiguousInconclusiveNotice() async {
        let h = makeHarness()
        signIn(h, accountID: "u1")
        await seedEvidence(h, accountID: "u1")
        h.repo.deleteAccountError = APIError.offline
        h.repo.accountStatusError = APIError.offline
        // The fence is set by the submit; status stays inconclusive.
        h.syncController.setDeletionFence(userID: "u1", fenced: true)

        let vm = AccountViewModel(container: h.container)
        await vm.confirmDelete()

        #expect(vm.deleteNotice == .failed)
        if case .signedIn = h.sessionStore.state {
        } else {
            Issue.record("must stay signed in on inconclusive outcome")
        }
    }

    @Test("202 pending revocation signs out with no error notice")
    func delete202SignsOut() async {
        let h = makeHarness()
        signIn(h, accountID: "u1")
        await seedEvidence(h, accountID: "u1")
        h.repo.deleteAccountResult = .pendingAppleRevocation

        let vm = AccountViewModel(container: h.container)
        await vm.confirmDelete()

        if case .signedOut = h.sessionStore.state {
        } else {
            Issue.record("expected signed out after 202 cleanup")
        }
        #expect(vm.deleteNotice == nil)
        #expect(h.container.deletionCoordinator.lastOutcomeWasPendingRevocation)
    }

    @Test("cleanup failure while signed in offers retry that completes")
    func cleanupRetryWhileSignedIn() async throws {
        let h = makeHarness()
        signIn(h, accountID: "u1")
        await seedEvidence(h, accountID: "u1")
        h.repo.deleteAccountResult = .completed
        h.repo.accountStatusResult = AccountStatusResponse(accountID: "u1", state: .deleted)
        // First attempt: ownership unverifiable, so cleanup fails after
        // purge and the marker is retained.
        await h.keychain.setLoadSnapshotError(.storageUnavailable(underlying: "test"))

        let vm = AccountViewModel(container: h.container)
        await vm.confirmDelete()

        #expect(vm.deleteNotice == .cleanupRetry)
        if case .signedIn = h.sessionStore.state {
        } else {
            Issue.record("failed cleanup must stay signed in")
        }
        #expect(await h.container.deletionCoordinator.pendingCleanupAccounts() == ["u1"])

        // Storage readable again: the notice retries the exact UUID without
        // another confirmation, and the marker clears on durable success.
        await h.keychain.setLoadSnapshotError(nil)
        await vm.retryCleanup()

        #expect(vm.deleteNotice == nil)
        if case .signedOut = h.sessionStore.state {
        } else {
            Issue.record("expected signed out after retried cleanup")
        }
        #expect(await h.container.deletionCoordinator.pendingCleanupAccounts().isEmpty)
    }

    // MARK: - Sign-out id stability

    @Test("sign-out keeps the Profile accessibility id and icon")
    func signOutIdentityStable() {
        #expect(ProfileView.signOutAccessibilityId == "ProfileSignOutButton")
        #expect(!ProfileView.signOutIcon.isEmpty)
        #expect(ProfileView.accountRowAccessibilityId == "ProfileAccountRow")
        #expect(AccountView.emailAccessibilityId == "AccountEmailValue")
        #expect(AccountView.deleteLocalDataAccessibilityId == "AccountDeleteLocalDataButton")
        #expect(AccountView.deleteAccountAccessibilityId == "AccountDeleteAccountButton")
        #expect(AccountView.deletionProgressAccessibilityId == "AccountDeletionProgress")
    }
}
