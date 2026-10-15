import Foundation
import Combine

/// One push on a tab's navigation path (per-tab-navigation-paths).
///
/// `profile` opens the Profile page on the tab that pushed it; `entry`
/// carries the tapped History entry snapshot for the pushed unified entry
/// form (EDIT for `manual`, LOCKED for imported — resolved at the
/// destination, so the snapshot never changes spec behavior); `namePicker`
/// carries the Track draft snapshot for the pushed shared picker and
/// `notesEditor` the running draft's notes snapshot for the pushed notes
/// page (completion closures resolve at the destination from the owning
/// tab's view model, so the route itself stays a value). Remaining
/// caller-local `NavigationLink`s (Manage Categories from Profile, pickers
/// inside the entry form and sheets) always sit under a non-empty path or
/// outside any tab bar, so every push past a tab root is path-observed.
/// Path-driven pushes (profile, entry, the Track name picker and notes
/// routes) hide the tab bar through the owning stack's path-driven
/// visibility (app-shell "Tab bar hidden on pushed destinations"); only
/// destinations reached through caller-local links (Manage Categories
/// from Profile, pickers inside the entry form and sheets — always under
/// a non-empty path or outside any tab bar) keep their own agreeing
/// backstop modifiers.
enum ShellRoute: Hashable {
    case profile
    case entry(TimeEntry)
    case namePicker(initialText: String)
    case notesEditor(initialText: String, entryName: String)
}

/// View model for the app shell (app-shell spec): owns the selected
/// destination and observes the persisted running draft so History and
/// Insights can show the compact timer.
@MainActor
final class AppShellViewModel: ObservableObject {
    enum Tab: Hashable {
        case track
        case history
        case insights
    }

    @Published var selectedTab: Tab = .track
    @Published private(set) var runningTimer: RunningTimerDraft?
    /// One independent push state per tab (per-tab-navigation-paths): opening
    /// Profile (or a History entry) on one tab never pre-pushes it on the
    /// others. Each tab's `NavigationStack(path:)` binds to its own path.
    @Published var trackPath: [ShellRoute] = []
    @Published var historyPath: [ShellRoute] = []
    @Published var insightsPath: [ShellRoute] = []

    let service: TimerService
    private var ticker: AnyCancellable?

    init(service: TimerService) {
        self.service = service
    }

    /// Pushes Profile onto the selected tab's own path. A no-op when Profile
    /// is already on that path (the toolbar button is unreachable while
    /// pushed — the tab bar hides — so this guards programmatic double-taps).
    func openProfile() {
        switch selectedTab {
        case .track:
            if !trackPath.contains(.profile) { trackPath.append(.profile) }
        case .history:
            if !historyPath.contains(.profile) { historyPath.append(.profile) }
        case .insights:
            if !insightsPath.contains(.profile) { insightsPath.append(.profile) }
        }
    }

    /// Whether a path transition popped Profile (was present, now absent).
    /// Pushes to Categories (a caller-local link, not a path value) never
    /// touch the path, so this fires once-on-exit only — never for
    /// Categories/editor traffic.
    static func profileWasPopped(old: [ShellRoute], new: [ShellRoute]) -> Bool {
        old.contains(.profile) && !new.contains(.profile)
    }

    /// Whether a tab's stack hides the tab bar (fix-tab-bar-return-jump):
    /// the bar shows iff the tab sits at its root. Every push past a tab
    /// root is path-observed (path-driven pushes plus the Track name picker
    /// route; remaining caller-local links always sit under a non-empty
    /// path or outside any tab bar), so a stack-level declaration never
    /// disagrees with a destination backstop. Pure function of depth —
    /// unit-tested, no view state involved.
    static func isTabBarHidden(path: [ShellRoute]) -> Bool {
        !path.isEmpty
    }

    /// Loads the persisted running draft (R2) and starts a periodic refresh so
    /// the compact timer stays live. Call on appear.
    func load() async {
        do {
            runningTimer = try await service.runningTimerDraft()
        } catch {
            runningTimer = nil
        }
        startTicker()
    }

    /// Stops the running timer from the compact surface, saving the entry
    /// with the draft's final categories and final notes in place
    /// (app-shell spec: keeps the current destination selected).
    func stopFromCompact() async {
        guard let running = runningTimer,
              !running.activityText.isEmpty,
              let startedAt = running.startedAt else { return }
        do {
            try await service.stopTimerDraft(
                text: running.activityText,
                categoryIDs: running.categoryIDs,
                startedAt: startedAt,
                endedAt: Date(),
                notes: running.notes
            )
            runningTimer = nil
        } catch {
            // Recoverable: keep the compact timer so the user can retry.
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let draft = try? await self.service.runningTimerDraft()
                    // Publish on real change only: @Published fires on every
                    // set, and a 1 Hz whole-shell re-render resets the
                    // entry-form calendar's browsed month back to the
                    // selection (month steppers snap back within a second).
                    // The compact timer ticks via its own TimelineView, so
                    // it never depended on this republish.
                    if draft != self.runningTimer {
                        self.runningTimer = draft
                    }
                }
            }
    }
}
