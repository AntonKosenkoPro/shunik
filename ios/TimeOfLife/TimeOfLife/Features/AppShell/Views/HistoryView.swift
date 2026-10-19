import SwiftUI

/// Read-only, day-grouped list of committed time entries (history-entry-list
/// spec). Day headers are static two-line blocks (label + total subline,
/// Calendar-Agenda-like) that pin under the navigation bar;
/// `HistoryViewModel` owns data only. Pinned bleed (row text crossing
/// beneath pinned headers) is accepted on every OS (design.md D8). The
/// navigation bar stays visible at every scroll position (the scroll-driven
/// collapse from the original change was reverted — see the
/// `revert-history-nav-collapse` change).
///
/// Tapping an entry row pushes the unified entry form onto this tab's
/// NavigationStack (remove-activities-layer D6 as amended by
/// fix-entry-form-gestures; entry-editor spec): editable for `manual`
/// entries, read-only for imported ones. The push (not a full-screen cover)
/// is what provides the leading-edge back gesture — a modal cover has no
/// back stack to pop. There is no activity detail sheet. Signed-out History
/// does not exist — the launch gate precedes every tab — so there is no
/// signed-out pull notice and no auth sheet here
/// (account-bound-local-data).
struct HistoryView: View {
    @EnvironmentObject var container: AppContainer
    /// Observed directly (not via `container`): `AppContainer` publishes
    /// nothing, so nested reads like `container.syncController.status` never
    /// invalidate this view — the status change would be missed and the list
    /// would stay stale after a sync (ProfileView precedent).
    @EnvironmentObject var sync: SyncController
    /// The shell's paths (per-tab-navigation-paths): entry taps append
    /// `.entry` to the History path only — never to another tab — and the
    /// destinations below (Profile + entry form) render from that path, so
    /// one `navigationDestination(for:)` serves this whole stack.
    @EnvironmentObject var shell: AppShellViewModel
    @Environment(\.undoManager)
    private var undoManager
    @StateObject private var vm: HistoryViewModel
    /// Owns the pull-to-refresh verdict flow (history-pull-to-sync spec).
    @StateObject private var pull: HistoryPullModel
    /// Presents the Log Time sheet (manual-entry spec). Owned by the shell
    /// so the [+] shares the nav-bar toolbar scope; the sheet and its
    /// refresh stay here.
    @Binding var isLogTimeActive: Bool
    /// Changes whenever the shell's running timer starts or stops (nil on
    /// stop). Lets History reload an entry saved from the compact timer
    /// without leaving the tab.
    private let refreshSignal: String

    init(
        store: LocalStore,
        undoBuffer: UndoBufferStore,
        sessionStore: SessionStore,
        sync: SyncController,
        connectivity: Connectivity,
        refreshSignal: String = "",
        logTimeActive: Binding<Bool> = .constant(false)
    ) {
        _vm = StateObject(wrappedValue: HistoryViewModel(store: store, undoBuffer: undoBuffer))
        _pull = StateObject(wrappedValue: HistoryPullModel(
            sync: sync,
            connectivity: connectivity
        ) { [weak sessionStore] in
            guard case let .signedIn(session) = sessionStore?.state else { return nil }
            return session.id
        })
        self.refreshSignal = refreshSignal
        _isLogTimeActive = logTimeActive
    }

    var body: some View {
        // VStack, not Group: the lifecycle modifiers below must hang on a
        // structurally stable container. On a bare conditional, every
        // `isLoading`/`dayGroups` branch flip re-fires `.task`/`onAppear`/
        // `onDisappear` — and `onDisappear` invalidates, so each load fed
        // the next one (infinite spinner loop). The pull notice renders
        // above the list, below the navigation bar (the shell owns the bar).
        VStack(spacing: 0) {
            if pull.notice != nil {
                PullNoticeBanner()
            }
            // ZStack, not Group (same stability rule as above, one level
            // down): the conditional content must not own the modifiers.
            ZStack {
                if vm.isLoading && vm.dayGroups.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.dayGroups.isEmpty {
                    EmptyState(
                        icon: "clock.arrow.circlepath",
                        title: L10n.historyEmptyTitle.text,
                        subtitle: L10n.historyEmptySubtitle.text
                    )
                } else {
                    historyList
                }
            }
        }
        // Opaque tab bar on iOS 18, glass on iOS 26+ (D8): the bar itself
        // is the only thing gated — list content always flows under it.
        .toolbarBackground(usesGlassTabBar ? .automatic : .visible, for: .tabBar)
        .background(Theme.backgroundPrimary.ignoresSafeArea())
        // System shake-to-undo for entry deletions (history-entry-list,
        // fix-87): the passive host returns this surface's undo manager so
        // shakes reach the registration `registerSystemUndo` owns.
        .background(ShakeFirstResponderHost(undoManager: undoManager))
        // `.task` alone misses re-entry after saving an entry on Track; a
        // plain `onAppear` reload would re-fire on every inner re-render.
        // The load is guarded by `needsReload` inside the VM.
        .task { await reloadAndRegister() }
        .onAppear { Task { await reloadAndRegister() } }
        // Entries can be saved on Track (or from the compact timer) while
        // History is off-screen; mark stale on leave so the next appear
        // reloads. Without this the `needsReload` guard serves the first
        // snapshot forever. Leaving also clears the transient pull notice.
        .onDisappear {
            vm.invalidate()
            pull.cancelNotice()
        }
        .onChange(of: refreshSignal) {
            Task { await invalidateReloadAndRegister() }
        }
        // A sync cycle merges relay state into LocalStore behind this view:
        // the Profile sheet covers History without firing onDisappear, so the
        // guarded reload above never runs. Observe the cycle directly and
        // reload on exit from `.syncing` (idle or error — a failed cycle may
        // have applied partial merges before throwing).
        .onChange(of: sync.status) { _, status in
            switch status {
            case .idle, .error:
                Task { await invalidateReloadAndRegister() }
            case .inactive, .syncing:
                break
            }
        }
        .sheet(isPresented: $isLogTimeActive) {
            LogTimeView(service: container.timerService) {
                Task { await invalidateReloadAndRegister() }
            }
        }
        // A pull-awaited cycle failure surfaces once, with a single OK
        // (history-pull-to-sync spec). Background cycles fail through the
        // same status property but never set the model's message, so they
        // stay dialog-free here (Profile status still reflects them).
        .alert(
            L10n.historySyncErrorTitle.text,
            isPresented: Binding(
                get: { pull.syncErrorMessage != nil },
                set: { if !$0 { pull.clearError() } }
            )
        ) {
            Button(L10n.commonOk.text, role: .cancel) {}
        } message: {
            Text(pull.syncErrorMessage ?? "")
        }
        // A refused/failed entry undo surfaces once, with a single OK
        // (history-entry-list spec: "refused with the existing persistence
        // error"). A system dialog through the existing alert pattern — no
        // banner, no toast (fix-87 deliberate choice, mirroring how
        // ProfileView surfaces its erase error).
        .alert(
            vm.undoError ?? "",
            isPresented: Binding(
                get: { vm.undoError != nil },
                set: { if !$0 { vm.clearUndoError() } }
            )
        ) {
            Button(L10n.commonOk.text, role: .cancel) { vm.clearUndoError() }
        }
        // The unified entry form pushes onto this tab's path
        // (per-tab-navigation-paths): EDIT for manual entries, LOCKED for
        // imported ones. The push provides the system back button and the
        // leading-edge pop gesture (a full-screen cover has no back stack,
        // which is why #50's gesture never recognized). Profile pushes on
        // this same path from the shell toolbar — one value destination
        // serves both, so opening Profile here never touches Track or
        // Insights. Leaving the pushed form reloads the day groups (edits
        // and deletes both land here) — the same invalidate/loadIfNeeded
        // path the CREATE sheet uses.
        .navigationDestination(for: ShellRoute.self) { route in
            switch route {
            case .profile:
                ProfileView()
                    .environmentObject(container)
                    .environmentObject(container.sessionStore)
            case .namePicker:
                // Unreachable: the Track picker route lives on the Track
                // path only. Exhaustiveness, no behavior.
                EmptyView()
            case .notesEditor:
                // Unreachable: the Track notes route lives on the Track
                // path only. Exhaustiveness, no behavior.
                EmptyView()
            case .categoryEditor:
                // Unreachable: the Track category-editor route lives on the
                // Track path only. Exhaustiveness, no behavior.
                EmptyView()
            case .entry(let entry):
                LogTimeView(
                    service: container.timerService,
                    editing: entry,
                    embeddedInNavigationStack: true
                ) {
                    Task { await invalidateReloadAndRegister() }
                }
                .environmentObject(container)
                .onDisappear {
                    Task { await invalidateReloadAndRegister() }
                }
            }
        }
    }

    /// Reload-then-register ordering: the registration reads the newest
    /// buffer row, which only exists after the delete transaction commits —
    /// registering before reload races it.
    private func reloadAndRegister() async {
        await vm.loadIfNeeded()
        await vm.registerSystemUndo(with: undoManager)
    }

    private func invalidateReloadAndRegister() async {
        vm.invalidate()
        await reloadAndRegister()
    }

    /// Native day-grouped list (D8): bare two-line headers pin under the
    /// navigation bar; pinned bleed (row text crossing beneath headers) is
    /// accepted on every OS. Chrome stripped to the page; the pull verdict
    /// flow, tap parity, and identifiers are unchanged from the bridge.
    private var historyList: some View {
        List {
            ForEach(vm.dayGroups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        EntryRow(
                            entry: entry,
                            icon: vm.icon(for: entry),
                            categoryNames: vm.categoryNames(for: entry),
                            timeframeText: vm.timeframeText(for: entry),
                            durationText: vm.durationText(for: entry),
                            isInProgress: vm.isInProgress(entry),
                            viaText: vm.viaText(for: entry),
                            hasNotes: vm.hasNotes(for: entry)
                        )
                        .listRowInsets(EdgeInsets(
                            top: 0,
                            leading: Theme.spacingMedium,
                            bottom: 0,
                            trailing: Theme.spacingMedium
                        ))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        // Tap → pushed unified entry form on this tab's path
                        // (history D6 as amended). No swipe/long-press actions.
                        .contentShape(Rectangle())
                        .onTapGesture { shell.historyPath.append(.entry(entry)) }
                        .accessibilityAddTraits(.isButton)
                    }
                } header: {
                    SectionHeader(
                        title: group.label,
                        subtitle: "\(group.total) \(L10n.historyTracked.text)"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await pull.refresh()
        }
        .accessibilityIdentifier("HistoryList")
    }

    /// Glass tab bar on iOS 26+; opaque bar on iOS 18 so no scrolled
    /// content shows through it (D8).
    private var usesGlassTabBar: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }
}

// MARK: - Pull notice (history-pull-to-sync)

/// Inline verdict below the navigation bar for offline pulls (one at a
/// time; newest pull wins). The signed-out notice is gone with the launch
/// gate — the only reachable signed-out surface is the auth gate itself.
/// `Theme` colors only.
private struct PullNoticeBanner: View {
    var body: some View {
        Text(L10n.historyPullOffline.text)
            .font(.footnote)
            .foregroundStyle(Theme.textPrimary)
            .padding(.vertical, Theme.spacingSmall)
            .padding(.horizontal, Theme.spacingMedium)
            .frame(maxWidth: .infinity)
            .background(Theme.backgroundSecondary)
            .accessibilityIdentifier("HistoryOfflineNotice")
    }
}

#if DEBUG
#Preview("History with entries") {
    let container = AppContainer.production()
    NavigationStack {
        HistoryView(
            store: container.localStore,
            undoBuffer: container.undoBuffer,
            sessionStore: container.sessionStore,
            sync: container.syncController,
            connectivity: container.connectivity
        )
    }
    .environmentObject(container)
    .environmentObject(container.syncController)
    .environmentObject(AppShellViewModel(service: container.timerService))
}

#Preview("History empty") {
    let container = AppContainer.production()
    NavigationStack {
        HistoryView(
            store: container.localStore,
            undoBuffer: container.undoBuffer,
            sessionStore: container.sessionStore,
            sync: container.syncController,
            connectivity: container.connectivity
        )
    }
    .environmentObject(container)
    .environmentObject(container.syncController)
    .environmentObject(AppShellViewModel(service: container.timerService))
}
#endif
