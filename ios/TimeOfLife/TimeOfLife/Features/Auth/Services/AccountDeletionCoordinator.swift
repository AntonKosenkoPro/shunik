// swiftlint:disable file_length
import Foundation
import OSLog

/// Owns the iOS account-deletion lifecycle for one process (account-deletion
/// spec 6.2/6.6/6.7): submit with 204/202 interpretation, ambiguous-outcome
/// status resolution, restart recovery, other-device confirmation, and
/// account-scoped durable cleanup. One coordinator per process, bound to the
/// original account UUID plus the process session generation — never to a
/// file that happens to be open.
///
/// Never counts as deletion: arbitrary 401/404, malformed responses,
/// offline/5xx, expired/missing/mismatched status evidence, or any generic
/// authentication rejection. Those lock with files intact (lock-not-wipe).
/// Only a scoped `deleted` verdict for the ORIGINAL UUID (or a 204/202 from
/// the authenticated DELETE) authorizes cleanup of exactly that UUID.
///
/// Fencing: while a deletion outcome is unresolved and throughout confirmed
/// cleanup, the target account's sync and local mutations stay fenced via
/// `SyncController.setDeletionFence`. A shutdown timeout is never permission
/// to erase under a live writer — cleanup waits for the cycle end (bounded)
/// and aborts to retry when the store is still live.
@MainActor
final class AccountDeletionCoordinator: ObservableObject {
    /// Outcome of an explicit deletion submit from Account.
    enum SubmitResult: Equatable {
        /// Purge complete (Apple revocation complete or N/A) and local
        /// cleanup finished. The caller returns to the auth gate.
        case completed
        /// Purge committed with durable pending automatic Apple revocation;
        /// local cleanup finished. The caller returns to the auth gate
        /// without claiming Apple unlinking completed.
        case pendingAppleRevocation
        /// The account needs fresh same-subject Apple authorization first
        /// (no stored revocable credential). The caller presents the native
        /// sheet; cancelling it sends nothing.
        case appleCredentialRequired
        /// The user cancelled the native Apple sheet: the intent is removed,
        /// nothing was sent, nothing changed.
        case cancelled
        /// No connection: nothing was sent, nothing was erased. The caller
        /// explains that a connection is required.
        case needsConnection
        /// No usable status evidence: refusing to send, because an ambiguous
        /// outcome could never be resolved. Files preserved.
        case missingEvidence
        /// Storage for the pre-send intent failed: nothing was sent.
        case storageUnavailable
        /// The outcome is ambiguous (lost response, 5xx, rejection, malformed
        /// success shape). Nothing is claimed; the intent stays fenced for
        /// scoped resolution or explicit cancel.
        case ambiguous
        /// Another submit is already in flight: duplicate ignored.
        case alreadyInFlight
    }

    /// Outcome of resolving a retained intent (restart, retry, or monitor).
    enum Resolution: Equatable {
        case noIntent
        /// Status confirms the original UUID is gone and cleanup finished.
        case cleanedUp
        /// Deletion confirmed but local cleanup failed after purge: the app
        /// is unauthenticated, the marker is retained, and the auth gate
        /// offers retry. Never reports the failed cleanup as success.
        case cleanupRetryNeeded
        /// The account still exists: no automatic replay. The caller offers
        /// explicit retry through the same single-alert interaction.
        case activeRequiresDecision
        /// No usable evidence or an inconclusive check: files preserved, the
        /// intent stays fenced.
        case inconclusive
        /// The verdict names a different UUID than the intent: never applied
        /// to another account. Files preserved.
        case mismatched
    }

    /// Outcome of the other-device session-rejection check.
    enum RejectionResult: Equatable {
        case cleanedUp
        case cleanupRetryNeeded
        /// Locked with files intact (active/inconclusive/missing evidence).
        case preserved
        case noMonitoredAccount
    }

    private static let logger = Logger(subsystem: "com.antonkosenko.timeoflifeapp", category: "accountDeletion")
    /// Minimum interval between other-device status checks (single-flight +
    /// bounded: checks run on auth failure/foreground/connectivity, never
    /// polling). Injectably small in tests.
    private let monitorMinInterval: TimeInterval

    private let repository: AuthRepository
    private let deletionStorage: AccountDeletionStorage
    private let keychain: KeychainStoring
    private let sessionStore: SessionStore
    private let cache: SessionCache
    private let syncController: SyncController
    private let localStore: LocalStore
    private let timerService: TimerService
    private let navigation: AppNavigationStack
    private let connectivity: Connectivity
    private let appleService: AppleSignInService
    private let authService: AuthService
    private let markerResolver: ActiveAccountFileResolver
    /// Native revocation observation, scoped per sign-in. Lazy: the sign-out
    /// closure references `self` (fence release), which cannot be captured
    /// before initialization completes.
    private lazy var appleObserver = AppleCredentialObserver(
        stateProvider: appleStateProvider,
        keychain: keychain,
        sessionStore: sessionStore
    ) { [weak authService, weak self] accountID in
        await authService?.logout()
        self?.handleSignOut(accountID: accountID)
    }
    private let appleStateProvider: AppleCredentialStateProviding
    /// Overrides the App Group container for database-file deletion (tests
    /// pin a throwaway directory; production uses the shared container).
    private let fileBaseURL: URL?

    private var isSubmitting = false
    private var statusCheckTask: Task<Resolution, Never>?
    private var lastMonitorCheckAt: Date?
    /// Set when a submit completes with durable pending Apple revocation.
    /// The auth gate shows the pending-unlink notice once; in-memory only
    /// (the durable truth was already acted on — cleanup finished).
    @Published private(set) var lastOutcomeWasPendingRevocation = false
    /// The account this device last signed in as (set by `resume`). The
    /// other-device check resolves only this UUID — never a file that
    /// happens to be open.
    private var monitoredAccountID: String?

    init(
        repository: AuthRepository,
        deletionStorage: AccountDeletionStorage,
        keychain: KeychainStoring,
        sessionStore: SessionStore,
        cache: SessionCache,
        syncController: SyncController,
        localStore: LocalStore,
        timerService: TimerService,
        navigation: AppNavigationStack,
        connectivity: Connectivity,
        appleService: AppleSignInService,
        authService: AuthService,
        markerResolver: ActiveAccountFileResolver = ActiveAccountFileResolver(),
        appleStateProvider: AppleCredentialStateProviding = LiveAppleCredentialStateProvider(),
        monitorMinInterval: TimeInterval = 30,
        fileBaseURL: URL? = nil
    ) {
        self.repository = repository
        self.deletionStorage = deletionStorage
        self.keychain = keychain
        self.sessionStore = sessionStore
        self.cache = cache
        self.syncController = syncController
        self.localStore = localStore
        self.timerService = timerService
        self.navigation = navigation
        self.connectivity = connectivity
        self.appleService = appleService
        self.authService = authService
        self.markerResolver = markerResolver
        self.monitorMinInterval = monitorMinInterval
        self.fileBaseURL = fileBaseURL
        self.appleStateProvider = appleStateProvider
    }

    // MARK: - Lifecycle hooks (wired by AppContainer)

    /// Called on every signed-in shell mount (fresh sign-in, restore,
    /// re-login): finishes another account's delayed cleanup, re-fences an
    /// intent for this account, and (re)starts native Apple observation when
    /// this device is Apple-authenticated. Never touches a newly active
    /// account's files or session.
    func resume(accountID: String) async {
        monitoredAccountID = accountID
        lastOutcomeWasPendingRevocation = false
        // Delayed cleanup for OTHER accounts' markers first: A confirmed
        // while B signs in erases only A, even with B active.
        if case .success(let markers) = await deletionStorage.loadCleanupMarkers() {
            for marker in markers where marker != accountID {
                _ = await performCleanup(accountID: marker)
            }
        }
        // Our own marker with us active should be impossible (server UUIDs
        // are never reassigned): preserve the live account and keep the
        // marker for operator diagnosis rather than erasing under it.
        // Our own pending intent: restore the fence so sync stays fenced
        // until a scoped verdict or explicit cancel.
        if case .success(let intent) = await deletionStorage.loadIntent(),
           let intent, intent.accountID == accountID {
            syncController.setDeletionFence(userID: accountID, fenced: true)
        }
        await appleObserver.start(accountID: accountID)
    }

    /// Called on sign-out (explicit or external): releases this account's
    /// fence and stops native observation. Deletion monitoring artifacts
    /// themselves are cleared by `AuthService.logout`.
    func handleSignOut(accountID: String) {
        syncController.setDeletionFence(userID: accountID, fenced: false)
        appleObserver.stop()
        if monitoredAccountID == accountID { monitoredAccountID = nil }
    }

    // MARK: - Explicit submit (Account)

    /// Submits permanent deletion for the signed-in account. The caller
    /// (AccountViewModel) owns the single alert, progress, and duplicate
    /// protection; this method additionally refuses concurrent submits.
    func submitDeletion(accountID: String) async -> SubmitResult {
        guard !isSubmitting else { return .alreadyInFlight }
        guard connectivity.isConnected else { return .needsConnection }
        guard case let .signedIn(current) = sessionStore.state, current.id == accountID else {
            return .missingEvidence
        }
        isSubmitting = true
        defer { isSubmitting = false }
        // Evidence BEFORE send: without a usable status credential an
        // ambiguous outcome could never be resolved, so refuse to send.
        guard case .success(let stored) = await deletionStorage.loadStatusCredential(accountID: accountID),
              let evidence = stored else {
            return .missingEvidence
        }
        let intent = AccountDeletionIntent(
            accountID: accountID,
            statusCredential: evidence.credential,
            phase: .intentPending,
            createdAt: Date()
        )
        switch await deletionStorage.saveIntent(intent) {
        case .failure:
            return .storageUnavailable
        case .success:
            break
        }
        // Fence sync for the account, then settle the in-flight owner
        // before sending. A shutdown timeout here only bounds the wait —
        // the send itself is server-linearized and any ambiguity resolves
        // through the fenced intent, never through assumption.
        syncController.setDeletionFence(userID: accountID, fenced: true)
        await syncController.waitForCycleEnd(timeout: 2)
        do {
            let outcome = try await repository.deleteAccount()
            guard await markCleanupRequired(intent: intent, evidence: evidence) else {
                // Purged server-side but the durable marker failed: report
                // retry (never success) — the next `resolveIntent` resumes
                // from the still-pending intent via a scoped status check.
                return .ambiguous
            }
            return await finishSubmit(outcome: outcome, accountID: accountID)
        } catch let error as APIError {
            // apple_credential_required is actionable (native sheet), not
            // deletion: the intent stays fenced for acquire-and-submit.
            if error.code == "apple_credential_required" {
                return .appleCredentialRequired
            }
            // Every other failure — offline, 5xx, rejection, malformed,
            // unexpected — is ambiguous: keep the fenced intent, claim
            // nothing, erase nothing.
            Self.logger.error("deleteAccount failed: \(error.localizedDescription, privacy: .public)")
            return .ambiguous
        } catch {
            Self.logger.error("deleteAccount failed: \(String(describing: error), privacy: .public)")
            return .ambiguous
        }
    }

    /// Durably marks the intent as cleanup-required after the purge
    /// committed. False when the marker write fails (report retry, never
    /// success — resolution resumes from the still-pending intent).
    private func markCleanupRequired(intent: AccountDeletionIntent, evidence: StoredStatusCredential) async -> Bool {
        if case .failure = await deletionStorage.saveIntent(
            AccountDeletionIntent(
                accountID: intent.accountID,
                statusCredential: evidence.credential,
                phase: .cleanupRequired,
                createdAt: intent.createdAt
            )
        ) {
            return false
        }
        return true
    }

    /// Finishes a submit whose purge committed: runs the exact-UUID cleanup
    /// and maps the server outcome. A failed cleanup reports retry, never
    /// success — even for a completed purge.
    private func finishSubmit(outcome: AccountDeletionOutcome, accountID: String) async -> SubmitResult {
        guard await performCleanup(accountID: accountID) else {
            return .ambiguous
        }
        switch outcome {
        case .completed:
            return .completed
        case .pendingAppleRevocation:
            lastOutcomeWasPendingRevocation = true
            return .pendingAppleRevocation
        }
    }
    /// Native-sheet cancellation clears the fenced intent and sends nothing:
    /// the account and data stay intact.
    /// Acquires the same-subject Apple revocable credential, then submits.
    /// Native-sheet cancellation clears the fenced intent and sends nothing:
    /// the account and data stay intact.
    func acquireCredentialAndSubmit(accountID: String) async -> SubmitResult {
        let credential: AppleCredential
        do {
            credential = try await appleService.signIn()
        } catch AppleSignInError.canceled {
            // Dismissed sheet: remove the fenced intent, send nothing.
            await cancelIntent(accountID: accountID)
            return .cancelled
        } catch {
            return .ambiguous
        }
        do {
            try await repository.acquireAppleDeletionCredential(
                identityToken: credential.identityToken,
                authorizationCode: credential.authorizationCode
            )
        } catch {
            Self.logger.error("acquireAppleDeletionCredential failed: \(String(describing: error), privacy: .public)")
            return .ambiguous
        }
        return await submitDeletion(accountID: accountID)
    }

    /// Dismisses the one-time pending-unlink gate notice.
    func dismissPendingUnlinkNotice() {
        lastOutcomeWasPendingRevocation = false
    }

    /// Account IDs with a retained cleanup marker (confirmed deletion whose
    /// local cleanup is scheduled or failed). The auth gate offers retry.
    func pendingCleanupAccounts() async -> [String] {
        switch await deletionStorage.loadCleanupMarkers() {
        case .success(let markers): return markers
        case .failure: return []
        }
    }

    /// Cancels a pending intent after an `active` verdict: removes the intent
    /// and resumes normal sync with exactly one owner. Never erases.
    func cancelIntent(accountID: String) async {
        if case .success(let intent) = await deletionStorage.loadIntent(),
           intent?.accountID == accountID {
            await deletionStorage.clearIntent()
        }
        syncController.setDeletionFence(userID: accountID, fenced: false)
        if case let .signedIn(current) = sessionStore.state, current.id == accountID {
            syncController.activate(userID: accountID)
        }
    }

    // MARK: - Intent resolution (restart, retry, monitor)

    /// Resolves the retained intent through the scoped status capability:
    /// `deleted` resumes cleanup without another login or confirmation;
    /// `active` offers explicit retry (no automatic replay); anything
    /// inconclusive preserves files with the fence held.
    func resolveIntent() async -> Resolution {
        if let task = statusCheckTask {
            return await task.value
        }
        let task: Task<Resolution, Never> = Task { [weak self] in
            guard let self else { return .inconclusive }
            return await self.resolveIntentBody()
        }
        statusCheckTask = task
        defer { statusCheckTask = nil }
        return await task.value
    }

    private func resolveIntentBody() async -> Resolution {
        guard case .success(let intent) = await deletionStorage.loadIntent(),
              let intent else { return .noIntent }
        guard case .success(let stored) = await deletionStorage.loadStatusCredential(accountID: intent.accountID),
              let evidence = stored else {
            return .inconclusive
        }
        let verdict: AccountStatusResponse
        do {
            verdict = try await repository.fetchAccountStatus(statusCredential: evidence.credential)
        } catch {
            Self.logger.error("status check failed: \(String(describing: error), privacy: .public)")
            return .inconclusive
        }
        guard verdict.accountID == intent.accountID else { return .mismatched }
        switch verdict.state {
        case .deleted:
            if case .success = await deletionStorage.saveIntent(
                AccountDeletionIntent(
                    accountID: intent.accountID,
                    statusCredential: evidence.credential,
                    phase: .cleanupRequired,
                    createdAt: intent.createdAt
                )
            ) {
                return await performCleanup(accountID: intent.accountID) ? .cleanedUp : .cleanupRetryNeeded
            }
            return .inconclusive
        case .active:
            return .activeRequiresDecision
        }
    }

    /// Other-device check after a generic session rejection (or
    /// foreground/connectivity recovery): single-flight, bounded by the
    /// monitor interval, erased only after a matched scoped `deleted`
    /// verdict. Active/inconclusive/expired/mismatched evidence preserves
    /// files with the normal lock-not-wipe behavior.
    func handleSessionRejection() async -> RejectionResult {
        guard let accountID = monitoredAccountID else { return .noMonitoredAccount }
        if let last = lastMonitorCheckAt, Date().timeIntervalSince(last) < monitorMinInterval {
            return .preserved
        }
        lastMonitorCheckAt = Date()
        guard case .success(let stored) = await deletionStorage.loadStatusCredential(accountID: accountID),
              let evidence = stored else {
            return .preserved
        }
        let verdict: AccountStatusResponse
        do {
            verdict = try await repository.fetchAccountStatus(statusCredential: evidence.credential)
        } catch {
            Self.logger.error("monitor status check failed: \(String(describing: error), privacy: .public)")
            return .preserved
        }
        guard verdict.accountID == accountID, verdict.state == .deleted else {
            return .preserved
        }
        syncController.setDeletionFence(userID: accountID, fenced: true)
        if case .success = await deletionStorage.saveIntent(
            AccountDeletionIntent(
                accountID: accountID,
                statusCredential: evidence.credential,
                phase: .cleanupRequired,
                createdAt: Date()
            )
        ) {
            return await performCleanup(accountID: accountID) ? .cleanedUp : .cleanupRetryNeeded
        }
        return .preserved
    }

    /// Retries confirmed cleanup from the auth gate after a post-purge local
    /// failure. Scoped to the exact UUID; never touches a newly active
    /// account.
    func retryCleanup(accountID: String) async -> Resolution {
        guard case .success(let markers) = await deletionStorage.loadCleanupMarkers(),
              markers.contains(accountID) else {
            return await resolveIntent()
        }
        return await performCleanup(accountID: accountID) ? .cleanedUp : .cleanupRetryNeeded
    }

    // MARK: - Cleanup

    /// Performs the durable account-scoped cleanup for exactly `accountID`
    /// (6.4–6.6): marker already durably scheduled by the caller.
    ///
    /// Ordering: fence + settle → discard draft without saving → end only
    /// this account's Live Activity → erase the file (own handle released
    /// first) → clear only matching auth/cache/navigation/marker ownership.
    /// New-account safety: when another account is active, only the target
    /// file is erased — session, navigation, Live Activity, and markers for
    /// the active account are never cleared.
    ///
    /// Returns false when any step fails after purge: the marker is retained
    /// and the auth gate offers retry. A repeated call after completed
    /// cleanup is a no-op success (missing files, absent artifacts).
    private func performCleanup(accountID: String) async -> Bool {
        // Durable marker BEFORE destructive work (callers ensure the intent
        // phase is already cleanupRequired; the marker survives even a
        // process kill mid-cleanup).
        if case .failure = await deletionStorage.addCleanupMarker(accountID: accountID) {
            return false
        }
        let currentID: String? = {
            if case let .signedIn(current) = sessionStore.state { return current.id }
            return nil
        }()
        let isTargetActive = (currentID == nil || currentID == accountID)

        // Settle the sync owner; a timeout is never permission to erase
        // under a live writer.
        syncController.setDeletionFence(userID: accountID, fenced: true)
        await syncController.waitForCycleEnd(timeout: 2)
        guard !syncController.isCycleLive else {
            Self.logger.error("cleanup deferred: sync cycle still live")
            return false
        }
        if isTargetActive {
            // End only the deleted account's Live Activity immediately —
            // no Saved face, no entry, no outbox row.
            await timerService.discardTimerDraftForDeletedAccount()
        }
        do {
            try await localStore.eraseAccount(userID: accountID, in: fileBaseURL)
        } catch {
            Self.logger.error("cleanup erase failed: \(String(describing: error), privacy: .public)")
            return false
        }
        if isTargetActive {
            guard await clearOwnedSessionState(accountID: accountID) else {
                return false
            }
        }
        syncController.setDeletionFence(userID: accountID, fenced: false)
        // Intent + marker removal only after durable success. A failed
        // marker write here leaves a no-op retry (files already gone).
        if case .success(let intent) = await deletionStorage.loadIntent(),
           intent?.accountID == accountID {
            await deletionStorage.clearIntent()
        }
        await deletionStorage.removeCleanupMarker(accountID: accountID)
        if monitoredAccountID == accountID { monitoredAccountID = nil }
        appleObserver.stop()
        return true
    }

    /// Clears only the deleted account's owned session artifacts: the
    /// cross-process marker only when it still names the deleted UUID
    /// (never when B is active — that branch never reaches here), the
    /// snapshot only while still bound to this account, then the Apple id,
    /// status credential, session, telemetry identity, navigation, and sync.
    /// False when ownership is unverifiable: the marker is retained and the
    /// gate retries rather than risk clearing another account's credentials.
    private func clearOwnedSessionState(accountID: String) async -> Bool {
        if markerResolver.readSessionUserID(base: fileBaseURL) == accountID {
            cache.clear()
        }
        switch await keychain.loadSnapshot() {
        case .success(let snapshot) where snapshot?.accountId == accountID:
            await keychain.removeSnapshot()
        case .success:
            break
        case .failure:
            Self.logger.error("cleanup deferred: snapshot unreadable")
            return false
        }
        await keychain.remove(key: .appleUserId)
        await deletionStorage.removeStatusCredential(accountID: accountID)
        if case let .signedIn(current) = sessionStore.state, current.id == accountID {
            sessionStore.setSignedOut()
        }
        SentryReporter.setUserID(nil)
        navigation.path = []
        navigation.resetTapRequests()
        syncController.deactivate()
        return true
    }
}
