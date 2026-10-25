import Foundation
import OSLog

/// View model for the Account page (Profile → Account, app-shell +
/// account-deletion specs). Owns deletion submission state, progress, and
/// result notices; the view stays declarative.
///
/// All labels come from `L10n` (EN + RU); all colors from `Theme`. The
/// destructive row, alert title, and confirmation button share the exact
/// copy **Delete account and local data** — exactly one confirmation alert,
/// no second confirmation anywhere. A native Apple authorization sheet for
/// Apple-created accounts without a stored revocable credential is
/// authentication, not an alert; dismissing it sends nothing.
@MainActor
final class AccountViewModel: ObservableObject {
    /// Result notices shown after a deletion attempt. An error/result notice
    /// is information, never a second deletion confirmation: retry
    /// re-presents the same single confirmation alert, cancel clears the
    /// fenced intent without erasing.
    enum DeleteNotice: Equatable {
        /// Generic or ambiguous failure (or inconclusive/mismatched status):
        /// nothing claimed, nothing erased. Retry re-presents the alert.
        case failed
        /// Offline: nothing sent. Retry when connected.
        case offline
        /// The scoped check confirms the account still exists: no automatic
        /// replay. Retry (same alert) or Cancel (clear the intent).
        case stillExists
        /// Deletion confirmed but local cleanup failed after purge while
        /// still signed in: the marker is retained and the auth gate would
        /// offer retry only after sign-out, so the notice itself offers
        /// retry here instead of stranding the marker.
        case cleanupRetry
    }

    @Published private(set) var isDeleting = false
    @Published var isShowingDeleteConfirm = false
    @Published var isShowingEraseConfirm = false
    @Published var isShowingSignOutConfirm = false
    @Published var deleteNotice: DeleteNotice?
    /// The last local-erase failure message, surfaced in an alert. Set only
    /// when the file survives on disk — the flow stays signed in for a retry
    /// instead of logging out and reporting success.
    @Published var eraseErrorMessage: String?

    private let container: AppContainer
    /// Duplicate-submission guard (view-level; the coordinator additionally
    /// refuses concurrent submits).
    private var submitTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.antonkosenko.shunik", category: "account")

    init(container: AppContainer) {
        self.container = container
    }

    /// The signed-in account's cached email (offline-capable, read-only).
    var email: String {
        if case let .signedIn(current) = container.sessionStore.state { return current.email }
        return ""
    }

    var deleteNoticeMessage: String? {
        switch deleteNotice {
        case .failed: return L10n.accountDeleteError.text
        case .offline: return L10n.accountDeleteOffline.text
        case .stillExists: return L10n.accountStillExists.text
        case .cleanupRetry: return L10n.accountCleanupRetryMessage.text
        case .none: return nil
        }
    }

    var deleteNoticeTitle: String {
        switch deleteNotice {
        case .failed: return L10n.accountDeleteFailedTitle.text
        case .offline: return L10n.accountDeleteOfflineTitle.text
        case .stillExists: return L10n.accountStillExistsTitle.text
        case .cleanupRetry: return L10n.accountCleanupRetryTitle.text
        case .none: return ""
        }
    }

    // MARK: - Sign out (confirmation-free, files kept)

    func signOut() async {
        let accountID = currentAccountID
        submitTask?.cancel()
        await container.authService.logout()
        if let accountID {
            container.deletionCoordinator.handleSignOut(accountID: accountID)
        }
        container.navigation.path = []
        container.navigation.resetTapRequests()
    }

    // MARK: - Delete local data (single confirmation, server-untouched)

    func eraseLocalData() async {
        // Deletes ONLY the active account's database file; a failed removal
        // throws, stays signed in, and surfaces a retryable error instead of
        // claiming success. On success the store ends unbound; logout clears
        // the session artifacts and the gate re-renders full-screen.
        // The account id is captured BEFORE logout (the session is already
        // cleared below): release this account's fence/observer afterwards.
        // Monitoring artifacts are cleared by `AuthService.logout` itself.
        let accountID = currentAccountID
        do {
            try await container.eraseLocalData()
        } catch {
            Self.logger.error("Erase local data failed: \(String(describing: error), privacy: .public)")
            eraseErrorMessage = error.localizedDescription
            return
        }
        await container.authService.logout()
        if let accountID {
            container.deletionCoordinator.handleSignOut(accountID: accountID)
        }
        container.navigation.path = []
        container.navigation.resetTapRequests()
    }

    // MARK: - Permanent deletion (one explicit alert)

    /// Confirms the single alert: runs the submit with progress and
    /// duplicate protection. Conflicting actions stay disabled via
    /// `isDeleting` while the coordinator fences sync for the account.
    func confirmDelete() async {
        guard submitTask == nil else { return }
        guard let accountID = currentAccountID else {
            deleteNotice = .failed
            return
        }
        submitTask = Task {
            await performDelete(accountID: accountID)
            submitTask = nil
        }
        await submitTask?.value
    }

    private func performDelete(accountID: String) async {
        isDeleting = true
        defer { isDeleting = false }
        let result = await container.deletionCoordinator.submitDeletion(accountID: accountID)
        await handleSubmitResult(result, accountID: accountID)
    }

    private func handleSubmitResult(_ result: AccountDeletionCoordinator.SubmitResult, accountID: String) async {
        switch result {
        case .completed, .pendingAppleRevocation, .cancelled:
            // Completed/pending: cleanup finished and the gate flipped —
            // nothing left to show here (the pending-unlink notice lives on
            // the gate). Cancelled: intent removed, nothing sent.
            deleteNotice = nil
        case .appleCredentialRequired:
            let acquired = await container.deletionCoordinator.acquireCredentialAndSubmit(accountID: accountID)
            // A repeated credential requirement means the server still has
            // no revocable token: report instead of looping the sheet.
            if acquired == .appleCredentialRequired {
                deleteNotice = .failed
            } else {
                await handleSubmitResult(acquired, accountID: accountID)
            }
        case .needsConnection:
            deleteNotice = .offline
        case .missingEvidence, .storageUnavailable:
            deleteNotice = .failed
        case .alreadyInFlight:
            break
        case .ambiguous:
            await handleAmbiguous(accountID: accountID)
        }
    }

    private func handleAmbiguous(accountID: String) async {
        // Resolve through the scoped status check — never assume. `deleted`
        // resumes cleanup without another login or confirmation; `active`
        // offers explicit retry, never automatic replay.
        switch await container.deletionCoordinator.resolveIntent() {
        case .noIntent, .cleanedUp:
            // Cleaned up (or nothing pending): the gate flipped. No notice.
            deleteNotice = nil
        case .cleanupRetryNeeded:
            // Confirmed but locally failed while still signed in: the gate
            // offers retry only after sign-out, so this notice retries here.
            deleteNotice = .cleanupRetry
        case .activeRequiresDecision:
            deleteNotice = .stillExists
        case .inconclusive, .mismatched:
            deleteNotice = .failed
        }
    }

    /// Retries confirmed cleanup after a `cleanupRetry` notice: resumes the
    /// exact UUID's cleanup without another login or confirmation. Success
    /// signs out through the gate; a repeated failure keeps the notice (and
    /// the gate offers retry after sign-out).
    func retryCleanup() async {
        guard let accountID = currentAccountID else {
            deleteNotice = nil
            return
        }
        isDeleting = true
        defer { isDeleting = false }
        switch await container.deletionCoordinator.retryCleanup(accountID: accountID) {
        case .cleanedUp, .noIntent:
            deleteNotice = nil
        case .cleanupRetryNeeded, .inconclusive, .mismatched, .activeRequiresDecision:
            deleteNotice = .cleanupRetry
        }
    }

    /// Retries after a `stillExists` notice through the same single-alert
    /// interaction (no automatic replay, no second confirmation shape).
    func retryDelete() {
        deleteNotice = nil
        isShowingDeleteConfirm = true
    }

    /// Cancels a fenced intent after an `active` verdict: removes the intent
    /// and resumes normal sync. Never erases.
    func cancelPendingDeletion() async {
        guard let accountID = currentAccountID else {
            deleteNotice = nil
            return
        }
        await container.deletionCoordinator.cancelIntent(accountID: accountID)
        deleteNotice = nil
    }

    private var currentAccountID: String? {
        if case let .signedIn(current) = container.sessionStore.state { return current.id }
        return nil
    }

    func reset() {
        submitTask?.cancel()
        submitTask = nil
        deleteNotice = nil
        eraseErrorMessage = nil
        isDeleting = false
        isShowingDeleteConfirm = false
        isShowingEraseConfirm = false
    }
}
