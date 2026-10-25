import SwiftUI
import Combine

/// Root view: the mandatory auth gate (account-bound-local-data).
///
/// Signed out → the auth flow, full-screen (app-shell spec): never the shell,
/// never a sheet, no dismiss path back into the app. Signed in → the app
/// shell. `SessionStore.state` is the single gate every surface consults.
///
/// The local-first lifecycle wiring moves behind the gate: everything that
/// touches the active account's store (cold-launch undo-buffer commit,
/// starter seeding, sync activation + the first-sync cycle) runs only once a
/// session exists — see `beginSignIn`. The gate itself never reads or
/// writes tracker data (local-first-store spec).
struct RootView: View {
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var container: AppContainer
    /// The account whose file has finished binding and is safe for tracker
    /// reads. Nil while the bind is in flight (fresh sign-in, restore,
    /// re-login) or after sign-out. The shell mounts only once this matches
    /// the signed-in session id (bind-then-reveal): no tracker read (Track /
    /// shell `.load()`) precedes `openLocalStore`, so a fresh sign-in never
    /// flashes `error.unknown` from `LocalStoreError.notBound`.
    @State private var boundUserID: String?
    /// Serializes the account-bound store lifecycle across rapid
    /// transitions: every sign-in/sign-out cancels its predecessor, so a
    /// late sign-out close can never unbind a newer sign-in's file
    /// (open-after-close).
    @State private var lifecycleTask: Task<Void, Never>?
    /// Auth-gate deletion state: the one-time pending-Apple-unlink notice
    /// (set when a submit completes with durable pending revocation) and the
    /// account id offered confirmed-cleanup retry after a post-purge local
    /// failure. Loaded when the signed-out branch appears; dismissing either
    /// never touches another account.
    @State private var showPendingUnlinkNotice = false
    @State private var cleanupRetryAccountID: String?

    var body: some View {
        Group {
            if session.isRestoring {
                // Unresolved restore: blank background, never the auth flow
                // — a restorable session must not flash the login screen
                // while `/me` is in flight. The color matches the OS launch
                // screen, so the handoff is invisible (steady-track-launch:
                // no splash, skeleton, spinner, or fade anywhere).
                launchBlank
            } else {
                gatedContent
            }
        }
            .background(Theme.backgroundPrimary.ignoresSafeArea())
            .task {
                // Restores a cached session (signed-in → the binding
                // placeholder above mounts and runs the startup) or leaves
                // the gate up. Restore already signs in optimistically from
                // cache before `/me` returns; the post-resolve trigger below
                // converges sync on verified credentials.
                await container.authService.restoreSession()
                if case .signedIn = session.state {
                    container.syncController.trigger(userID: sessionUserID())
                }
            }
            .onChange(of: session.state) { _, newState in
                switch newState {
                case .signedIn:
                    break
                case .signedOut:
                    beginSignOut()
                }
            }
            .onChange(of: container.connectivity.isConnected) { _, connected in
                if connected, case .signedIn = session.state {
                    container.syncController.trigger(userID: sessionUserID())
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                // Foregrounding never touches the undo buffer (buffered
                // deletions stay restorable until their push succeeds).
                if case .signedIn = session.state {
                    container.syncController.trigger(userID: sessionUserID())
                }
            }
    }

    /// The pre-mount hold: full-bleed background only, matching the OS
    /// launch screen color — the handoff from the system launch image is
    /// invisible, and there is deliberately no brand, text, spinner, or
    /// skeleton here (steady-track-launch: nothing says "wait").
    private var launchBlank: some View {
        Theme.backgroundPrimary
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    /// The signed-in/signed-out gate (restoring resolved): the auth flow
    /// full-screen while signed out, the shell once the account's store is
    /// bound, seeded, and snapshot-loaded — the first paint is complete
    /// (steady-track-launch).
    private var gatedContent: some View {
        Group {
            switch session.state {
        case .signedIn(let current):
            if boundUserID == current.id {
                AppShellView(vm: AppShellViewModel())
                    .environmentObject(container)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Bind-then-reveal: the gate holds a blank background (never
                // a spinner or splash) until the account's file is bound. The
                // startup runs here — not in `onChange` — so it fires on
                // every shell mount, including the restore-driven one.
                // A failed bind keeps the gate up with the error surfaced
                // instead of the shell — the store is unbound, so no
                // tracker read may mount.
                if container.localStoreOpenError != nil {
                    // Bind failure dead-ends here without an escape hatch:
                    // beginSignIn (the only site that clears the error via
                    // openLocalStore) runs solely in the blank hold below,
                    // and the shell with Profile's sign-out is unreachable
                    // while this gate is up. So offer sign-out right here
                    // (same L10n key + logout shape as ProfileView) — the
                    // next sign-in retries the bind.
                    VStack(spacing: 12) {
                        Text(L10n.errorLocalPersistence.text)
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("LocalStoreOpenError")
                        Button(L10n.profileSignOut.text, role: .destructive) {
                            Task { await container.authService.logout() }
                        }
                        .accessibilityIdentifier("GateSignOutButton")
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    launchBlank
                        .task { beginSignIn(userID: current.id) }
                }
            }
        case .signedOut:
            AuthFlowView()
                .task { await loadGateDeletionState() }
                .overlay(alignment: .top) {
                    if showPendingUnlinkNotice {
                        pendingUnlinkBanner
                    }
                }
                .alert(
                    L10n.accountCleanupRetryTitle.text,
                    isPresented: Binding(
                        get: { cleanupRetryAccountID != nil },
                        set: { if !$0 { cleanupRetryAccountID = nil } }
                    )
                ) {
                    Button(L10n.accountCleanupRetryConfirm.text) {
                        Task { await retryGateCleanup() }
                    }
                    .accessibilityIdentifier("GateCleanupRetryButton")
                    Button(L10n.commonOk.text, role: .cancel) { cleanupRetryAccountID = nil }
                } message: {
                    Text(L10n.accountCleanupRetryMessage.text)
                }
        }
        }
    }

    // swiftlint:disable:next todo
    // SHUNIK-TODO: scaffold sign-in — binds the account store, then reveals
    // the shell. Pet-care preload will hook in here.
    private func beginSignIn(userID: String) {
        lifecycleTask?.cancel()
        lifecycleTask = Task {
            if Task.isCancelled { return }
            // Deletion-lifecycle resume: finishes another account's delayed
            // cleanup (exact UUID only), re-fences our own pending intent,
            // and (re)starts native Apple observation. Never touches the
            // newly active account's files or session.
            await container.deletionCoordinator.resume(accountID: userID)
            if Task.isCancelled { return }
            let ready = await container.prepareAccountStore(userID: userID)
            if Task.isCancelled { return }
            guard case let .signedIn(current) = session.state, current.id == userID else { return }
            // A failed prepare leaves the store unbound: the gate stays up
            // (the error is surfaced via `localStoreOpenError` above) and
            // `boundUserID` is never set. The next sign-in retries.
            guard ready else { return }
            boundUserID = userID
            // Crash-reporting identity (observability Stage 0): opaque
            // account id only, never email.
            SentryReporter.setUserID(userID)
            container.syncController.activate(userID: userID)
        }
    }

    /// Loads auth-gate deletion state when the signed-out branch appears:
    /// the pending-unlink notice (if the last submit completed with durable
    /// pending Apple revocation) and cleanup retry (if a confirmed deletion
    /// left a local marker behind).
    private func loadGateDeletionState() async {
        showPendingUnlinkNotice = container.deletionCoordinator.lastOutcomeWasPendingRevocation
        let markers = await container.deletionCoordinator.pendingCleanupAccounts()
        cleanupRetryAccountID = markers.first
    }

    /// One-time pending Apple-unlink notice: informational only, never a
    /// confirmation. Dismissing clears it without touching any account.
    private var pendingUnlinkBanner: some View {
        HStack {
            Text(L10n.accountPendingAppleUnlink.text)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button(L10n.commonOk.text) {
                container.deletionCoordinator.dismissPendingUnlinkNotice()
                showPendingUnlinkNotice = false
            }
        }
        .padding()
        .background(Theme.backgroundPrimary)
        .accessibilityIdentifier("GatePendingUnlinkBanner")
    }

    /// Retries confirmed cleanup for the exact UUID from the gate, then
    /// reloads the remaining markers: a second pending account is offered
    /// next instead of hiding until the gate re-appears.
    private func retryGateCleanup() async {
        guard let accountID = cleanupRetryAccountID else { return }
        _ = await container.deletionCoordinator.retryCleanup(accountID: accountID)
        cleanupRetryAccountID = await container.deletionCoordinator.pendingCleanupAccounts().first
    }

    /// Tears down the signed-in lifecycle on every transition to `.signedOut`
    /// (plain logout and server-driven revocation alike): stops sync, clears
    /// stale auth routes so the gate never reopens on a pre-filled OTP
    /// screen, hides the shell, then closes the account's file (logout keeps
    /// all files) — but only after the in-flight cycle actually ended and
    /// only while still signed out, so a fast re-login's file stays bound
    /// (open-after-close).
    private func beginSignOut() {
        // Sync stops before the file closes: an in-flight cycle aborts at
        // its next stage guard, then the account's file goes dormant.
        container.syncController.deactivate()
        // Crash-reporting identity (observability Stage 0): a signed-out
        // device must not attribute later crashes to the previous account.
        SentryReporter.setUserID(nil)
        container.navigation.path = []
        container.navigation.resetTapRequests()
        boundUserID = nil
        // A stale bind error must never leak into a later sign-in: the error
        // branch's sign-out is the only escape from a failed bind, and the
        // next beginSignIn clears on entry anyway — belt and braces.
        container.localStoreOpenError = nil
        lifecycleTask?.cancel()
        lifecycleTask = Task {
            // Other-device deletion check: after a generic session rejection
            // the monitor confirms deletion with the original UUID's own
            // valid status credential, or locks with files intact. Explicit
            // sign-outs cleared their monitoring in `AuthService.logout`, so
            // this is a no-op for them.
            _ = await container.deletionCoordinator.handleSessionRejection()
            await waitForSyncShutdown()
            guard !Task.isCancelled else { return }
            // Rapid re-login flips the state before the close runs: skip it.
            // The guard and the close share one MainActor turn, so no flip
            // can slip between them — the close always precedes a later open.
            guard case .signedOut = session.state else { return }
            await container.closeLocalStore()
        }
    }

    /// Waits until SyncController's in-flight cycle actually ends
    /// (`deactivate()` only requests cancellation) so `closeLocalStore`
    /// never pulls the file out from under a running cycle — which would
    /// surface `notBound` as `.error` instead of `.inactive` and strand the
    /// next sign-in's `activate` (it only runs from `.inactive`). Bounded:
    /// the cycle is already cancelled, so it resolves on its next
    /// suspension point. Delegates to the controller's state publisher
    /// (no busy-poll).
    private func waitForSyncShutdown() async {
        await container.syncController.waitForCycleEnd(timeout: 2)
    }

    /// The authenticated session's `userId` (empty when signed out — callers
    /// gate on `session.state` first). Feeds the sync same-account guard.
    private func sessionUserID() -> String {
        if case let .signedIn(session) = session.state { return session.id }
        return ""
    }
}
