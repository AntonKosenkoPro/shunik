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

    var body: some View {
        Group {
            if session.isRestoring {
                restoringSplash
            } else {
                gatedContent
            }
        }
            .background(Theme.backgroundPrimary.ignoresSafeArea())
            .task {
                // Restores a cached session (signed-in → the binding
                // placeholder above mounts and runs the startup) or leaves
                // the gate up.
                await container.authService.restoreSession()
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
                    // Island Stop while suspended: the Darwin signal may
                    // have been missed, so reap here too (the entry-recency
                    // heuristic resolves Saved-vs-silent; live-activities D8).
                    Task { await container.timerService.endOrphanedActivities() }
                }
            }
    }

    /// Launch restore unresolved (cold start always restores): the app
    /// brand (same mark + name as the welcome screen) over a spinner, never
    /// the auth flow — a restorable session must not flash the login screen
    /// while `/me` is in flight.
    private var restoringSplash: some View {
        VStack(spacing: Theme.spacingMedium) {
            Image("BrandMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 68)
                .foregroundStyle(Theme.accentPrimary)
                .accessibilityHidden(true)
            Text(L10n.appName.text)
                .font(.largeTitle.bold())
                .foregroundStyle(Theme.textPrimary)
            ProgressView()
                .padding(.top, Theme.spacingSmall)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("RestoringSplash")
    }

    /// The signed-in/signed-out gate (restoring resolved): the auth flow
    /// full-screen while signed out, the shell once the account's store is
    /// bound and seeded, a spinner in between.
    private var gatedContent: some View {
        Group {
            switch session.state {
        case .signedIn(let current):
            if boundUserID == current.id {
                AppShellView(
                    vm: AppShellViewModel(service: container.timerService),
                    container: container
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Bind-then-reveal: the gate stays up (a spinner, never
                // the shell) until the account's file is bound. The
                // startup runs here — not in `onChange` — so it fires on
                // every shell mount, including the restore-driven one.
                // A failed bind keeps the gate up with the error surfaced
                // instead of the shell — the store is unbound, so no
                // tracker read may mount.
                if container.localStoreOpenError != nil {
                    // Bind failure dead-ends here without an escape hatch:
                    // beginSignIn (the only site that clears the error via
                    // openLocalStore) runs solely in the spinner branch,
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
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .task { beginSignIn(userID: current.id) }
                }
            }
        case .signedOut:
            AuthFlowView()
        }
        }
    }

    /// Runs once per signed-in shell mount: every sign-in path (fresh OTP/
    /// Apple sign-in, silent session restore at launch, re-login) lands here.
    /// Ordering matters (seed-before-reveal): the account's file is opened
    /// (`lifio_<userId>.db` via `prepareAccountStore`, account-bound-store
    /// spec — nothing may touch a tracker file before an account is bound),
    /// a restart finalizes deletions buffered by the previous process, and
    /// starter categories seed idempotently (per-file marker) — all BEFORE
    /// the shell mounts, so the first Track paint already carries the seed.
    /// Sync activation (pull-first first-sync, sync-client spec) runs after
    /// the reveal, in the background; Track converges on pulled data via its
    /// sync-exit reload.
    ///
    /// The caller cancels superseded lifecycles, so every suspension point
    /// re-checks cancellation and the live session: a sign-out that lands
    /// mid-prepare must neither reveal the shell nor activate sync for it.
    private func beginSignIn(userID: String) {
        lifecycleTask?.cancel()
        lifecycleTask = Task {
            if Task.isCancelled { return }
            let ready = await container.prepareAccountStore(userID: userID)
            if Task.isCancelled { return }
            guard case let .signedIn(current) = session.state, current.id == userID else { return }
            // A failed prepare leaves the store unbound (failed open) or
            // bound-but-unseeded (failed seed): either way the gate stays up
            // (the error is surfaced via `localStoreOpenError` above) and
            // `boundUserID` is never set — no tracker read may mount. The
            // next sign-in (or relaunch restore) retries the prepare.
            guard ready else { return }
            boundUserID = userID
            container.syncController.activate(userID: userID)
        }
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
        container.navigation.path = []
        container.navigation.resetTapRequests()
        boundUserID = nil
        // A stale bind error must never leak into a later sign-in: the error
        // branch's sign-out is the only escape from a failed bind, and the
        // next beginSignIn clears on entry anyway — belt and braces.
        container.localStoreOpenError = nil
        lifecycleTask?.cancel()
        lifecycleTask = Task {
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
