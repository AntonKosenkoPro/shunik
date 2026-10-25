import SwiftUI

/// The Profile destination (app-shell spec): the Account hub (email +
/// sign-out + local/permanent deletion live in Account), sync status with
/// Sync now, on-device category management, and version. Signed-in only —
/// the launch gate guarantees a session, so there is no "Enable Sync" row and
/// no auth sheet. No activity management exists (no activity catalog —
/// remove-activities-layer). Profile is a pushed page (back navigation, no
/// Done): it renders inside the presenting tab's NavigationStack, and
/// Account + Manage Categories push from here the same way.
struct ProfileView: View {
    @EnvironmentObject var container: AppContainer
    /// The signed-in session (Profile renders only behind the launch gate):
    /// supplies the `userId` the sync same-account guard checks against.
    @EnvironmentObject var session: SessionStore
    /// Observed directly (not via `container`): `AppContainer` publishes
    /// nothing, so nested reads like `container.syncController.status` never
    /// invalidate this view — the status row froze on "Syncing…" and the
    /// Sync now button never re-enabled. Separate environment objects (as in
    /// `TimeOfLifeApp`) subscribe to the real publishers.
    @EnvironmentObject var sync: SyncController
    /// Last successful-sync date (fix-sync-status-row): feeds the age
    /// subtitle under "Syncing…" so the status row keeps its two-line height
    /// across states instead of jumping. Nil before the first sync.
    @State private var lastIdleDate: Date?

    /// Sign-out row contract (fix-profile-signout-row, issue #68): shared
    /// `ListRow` geometry with a leading icon + danger tint, mirroring the
    /// local-data row. The row moved to Account (Profile → Account) and keeps
    /// its icon + accessibility id there; pinned by `ProfileSignOutRowTests`
    /// and the Account navigation tests.
    static let signOutIcon = "rectangle.portrait.and.arrow.right"
    static let signOutAccessibilityId = "ProfileSignOutButton"
    /// Stable id for the Profile → Account navigation row (Account.md).
    static let accountRowAccessibilityId = "ProfileAccountRow"

    var body: some View {
        List {
            accountSection
            versionFooter
        }
        .navigationTitle(L10n.profileTitle.text)
        .navigationBarTitleDisplayMode(.inline)
        // Pushed page (per-tab-navigation-paths): presents with system Back
        // and no tab-switch path. The tab bar hides through the owning
        // stack's path-driven visibility (fix-tab-bar-return-jump) — this
        // view declares nothing, so pop restores the bar in the same pass.
        // Account pushes from here on the same tab path (caller-local link,
        // like Manage Categories), so it inherits the hidden tab bar and
        // system Back for free.
        .accessibilityIdentifier("Profile")
    }

    // MARK: - Account

    private var accountSection: some View {
        Section(L10n.profileAccount.text) {
            NavigationLink {
                AccountView(container: container)
                    .environmentObject(container)
                    .environmentObject(session)
            } label: {
                ListRow(title: L10n.accountTitle.text, icon: "person.crop.circle", subtitle: session.cachedEmail)
            }
            .accessibilityIdentifier(Self.accountRowAccessibilityId)
            syncStatusRow
        }
        // Remember the last idle date so the syncing/error branches can keep
        // the row's two-line height with real content (no layout jump).
        .onChange(of: sync.status, initial: true) { _, status in
            if case let .idle(date) = status {
                lastIdleDate = date
            }
        }
    }

    // Single TimelineView above the switch (fix-sync-status-row): the row must
    // keep one stable view structure across idle/syncing/error — swapping view
    // types or adding/removing the trailing button re-lays-out the section
    // and the screen jumps on every tap of Sync now.
    @ViewBuilder private var syncStatusRow: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            switch sync.status {
            case .inactive:
                EmptyView()
            case .syncing:
                ListRow(
                    title: L10n.profileSyncing.text,
                    icon: "arrow.triangle.2.circlepath",
                    subtitle: rememberedAgeSubtitle(now: context.date)
                ) {
                    syncButton(disabled: true)
                }
            case let .idle(date):
                ListRow(
                    title: L10n.profileSyncedSuccessfully.text,
                    icon: "checkmark.icloud",
                    subtitle: Self.ageSubtitle(since: date, now: context.date)
                ) {
                    syncButton(disabled: false)
                }
            case let .error(message):
                ListRow(
                    title: L10n.profileSyncError.text,
                    icon: "exclamationmark.icloud",
                    subtitle: message.isEmpty ? rememberedAgeSubtitle(now: context.date) : message
                ) {
                    syncButton(disabled: false)
                }
            }
        }
    }

    /// Trailing sync action on the status row (fix-sync-status-row): same
    /// call and automation id as the retired separate row. Present (disabled)
    /// while syncing so the row structure never changes between states.
    /// VoiceOver label reuses `profile.syncNow` — no new strings.
    private func syncButton(disabled: Bool) -> some View {
        Button {
            Task { await sync.syncNow(userID: sessionUserID) }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.body)
                .foregroundStyle(Theme.accentPrimary)
                .frame(minWidth: Theme.minTapArea, minHeight: Theme.minTapArea)
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        // `.disabled` alone does not restyle a custom label — without this
        // the button looks tappable while syncing (WelcomeView precedent).
        .opacity(disabled ? 0.6 : 1)
        .accessibilityIdentifier("ProfileSyncNowButton")
        .accessibilityLabel(L10n.profileSyncNow.text)
    }

    /// Age subtitle from a known date ("1 minute ago", "Меньше минуты назад").
    private static func ageSubtitle(since date: Date, now: Date) -> String {
        SyncRelativeTime.subtitle(
            since: date,
            now: now,
            ago: L10n.profileLastSyncedAgo.text,
            justNow: L10n.profileLastSyncedJustNow.text
        )
    }

    /// Age of the last successful sync, if any (nil before the first sync).
    private func rememberedAgeSubtitle(now: Date) -> String? {
        lastIdleDate.map { Self.ageSubtitle(since: $0, now: now) }
    }

    // swiftlint:disable:next todo
    // SHUNIK-TODO: scaffold — the pet-care on-device section will live here.

    /// Trailing diagnostic version footer (add-version-label-release): plain
    /// footer text with no row/card, so it stays dim and never reads as
    /// tappable. Plain `Text`, so VoiceOver exposes it as a static label.
    /// `.caption` scales with Dynamic Type; `Theme.textSecondary` resolves
    /// for light/dark.
    private var versionFooter: some View {
        Section {
            EmptyView()
        } footer: {
            Text(AppVersion.text)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("ProfileVersionLabel")
        }
    }

    /// The authenticated session's `userId` (empty when signed out — Profile
    /// is unreachable then; the guard refuses an empty-id trigger anyway).
    private var sessionUserID: String {
        if case let .signedIn(current) = session.state { return current.id }
        return ""
    }
}

#if DEBUG
#Preview("Profile") {
    let container = AppContainer.production()
    NavigationStack {
        ProfileView()
            .environmentObject(container)
            .environmentObject(container.sessionStore)
            .environmentObject(container.syncController)
    }
}
#endif
