// swiftlint:disable file_length
import SwiftUI

/// The stable Track timer layout, built on the adaptive dual-flow stack
/// (refine-track-recents D1): navigation title, top spacer, completion mark,
/// timer numbers/status, reserved error region, central separator, name
/// field / locked name, main action, running tags / Recents, bottom spacer,
/// tab bar. The top and bottom spacers share a 48 pt cap and split slack
/// equally; surplus beyond twice the cap goes to the central separator. D10
/// makes the content height around the main action state-invariant (reserved
/// idle preparation slot, fixed-height action slot) and pins the bottom flow
/// under wrapped-error growth.
///
/// Capture is plain text (remove-activities-layer): the name field is the
/// only idle input; while running the name locks and the shared ordered
/// `TagSelector` takes the below-button slot where Recents was (D4) — the
/// field and the button never move on state switch.
struct TrackContent: View {
    @ObservedObject var vm: TrackViewModel
    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize
    @State private var actionSlotWidth: CGFloat = 0
    @State private var measuredErrorRegionHeight: CGFloat = 0

    /// The spike-approved shared maximum for both adaptive spacers
    /// (refine-track-recents D1/D7).
    let spacerCap: CGFloat
    /// Opens the shared name picker through the owning tab's path
    /// (fix-tab-bar-return-jump): a `ShellRoute` value, so the stack-level
    /// tab-bar visibility observes the push. Defaults to no-op for
    /// previews and picker-less hosts.
    let onOpenNamePicker: () -> Void
    /// Opens the running notes editor through the owning tab's path (same
    /// contract as the name picker). Defaults to no-op for previews.
    let onOpenNotesEditor: () -> Void

    init(
        vm: TrackViewModel,
        spacerCap: CGFloat = 48,
        onOpenNamePicker: @escaping () -> Void = {},
        onOpenNotesEditor: @escaping () -> Void = {}
    ) {
        self.vm = vm
        self.spacerCap = spacerCap
        self.onOpenNamePicker = onOpenNamePicker
        self.onOpenNotesEditor = onOpenNotesEditor
    }

    var body: some View {
        timerContent
            .background(Theme.backgroundPrimary.ignoresSafeArea())
            .onPreferenceChange(MainActionSlotWidthKey.self) { actionSlotWidth = $0 }
            .onPreferenceChange(TrackErrorRegionHeightKey.self) { measuredErrorRegionHeight = $0 }
    }

    // MARK: - Timer content

    private var timerContent: some View {
        AdaptiveVerticalLayout(
            spacerCap: spacerCap,
            topOverflow: topOverflow,
            topContent: { topFlow },
            bottomContent: { bottomFlow }
        )
    }

    // MARK: - Top flow

    private var topFlow: some View {
        VStack(spacing: 0) {
            completionMarkRegion
            NumericTimerReadout(state: vm.state, elapsed: vm.elapsed)
            errorRegion
                .padding(.top, Theme.spacingMedium)
        }
        .padding(.horizontal, Theme.screenHorizontalPadding)
        .frame(maxWidth: Theme.maxContentWidth)
        .frame(maxWidth: .infinity)
    }

    /// Reserved completion-mark region: keeps its height in every state and
    /// shows the saved checkmark without moving the timer below it.
    private var completionMarkRegion: some View {
        Color.clear
            .overlay {
                if case .saved = vm.state {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.accentPrimary)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 28)
    }

    /// Reserved non-field-error region immediately above the name/tags
    /// flow. When empty it preserves geometry; when an error shows, the
    /// banner keeps its production identifier, wraps without being cut, and
    /// grows past the reserved height. Both branches measure their height so
    /// `topOverflow` (growth beyond the reservation) feeds the D10 pinned
    /// spacing model and resets to zero when the error clears.
    @ViewBuilder private var errorRegion: some View {
        if let errorMessage = vm.errorMessage {
            ErrorBanner(
                message: errorMessage,
                accessibilityId: "TrackErrorBanner"
            )
            .frame(minHeight: Self.errorRegionHeight, alignment: .top)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: TrackErrorRegionHeightKey.self,
                        value: geometry.size.height
                    )
                }
            )
        } else {
            Color.clear
                .frame(height: Self.errorRegionHeight)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: TrackErrorRegionHeightKey.self,
                            value: geometry.size.height
                        )
                    }
                )
        }
    }

    /// D10: the top flow's growth beyond its state-invariant baseline — the
    /// wrapped error region beyond its reservation. The pinned spacing model
    /// absorbs it from the top spacer first, then the central separator, so
    /// the main action stays stationary.
    private var topOverflow: CGFloat {
        max(0, measuredErrorRegionHeight - Self.errorRegionHeight)
    }

    /// Reserved error-region height: two scaled caption lines plus breathing
    /// room so a wrapped localized error stays inside the reservation.
    private static var errorRegionHeight: CGFloat {
        UIFontMetrics(forTextStyle: .caption1).scaledValue(for: 16) * 2 + Theme.spacingExtraSmall
    }

    // MARK: - Bottom flow

    private var bottomFlow: some View {
        VStack(spacing: 0) {
            nameControl
            primaryAction
                .padding(.top, Theme.spacingLarge)
            belowActionSlot
                .padding(.top, Theme.spacingLarge)
        }
        .padding(.horizontal, Theme.screenHorizontalPadding)
        .frame(maxWidth: Theme.maxContentWidth)
        .frame(maxWidth: .infinity)
        // State swaps must be instant: without this the button tint/label
        // crossfades instead of appearing in place.
        .transaction { $0.animation = nil }
    }

    /// Below the Start/Stop button: Recents while idle, the live tag
    /// selector while running. Both branches stay mounted and the inactive
    /// one hides via opacity, so the slot keeps the taller branch's height
    /// in every state — the name field and the button above never move on
    /// state switch, and the tags sit where Recents was instead of pushing
    /// the button down. Hit testing and accessibility follow the visible
    /// branch (opacity hiding preserves layout while keeping the hidden
    /// branch out of hit testing and accessibility).
    @ViewBuilder private var belowActionSlot: some View {
        ZStack(alignment: .top) {
            recentActivities
                .opacity(vm.state.isRunning ? 0 : 1)
                .allowsHitTesting(!vm.state.isRunning)
                .accessibilityHidden(vm.state.isRunning)
            runningTagSelector
                .opacity(vm.state.isRunning ? 1 : 0)
                .allowsHitTesting(vm.state.isRunning)
                .accessibilityHidden(!vm.state.isRunning)
        }
    }

    // MARK: - Name capture (plain text, remove-activities-layer 4.1/4.2)

    /// Idle/ready/saved: the name push row opening the shared picker.
    /// Running/error: the locked name plus the standalone notes button.
    /// Saving: the plain locked name label (mid-flight, no editing).
    @ViewBuilder private var nameControl: some View {
        switch vm.state {
        case .idle, .ready, .saved:
            nameRow
        case .running, .error:
            runningNameRow
        case .saving:
            lockedNameLabel
        }
    }

    /// Name push row (dedicated-name-picker): tapping pushes the shared
    /// picker through the owning tab's path (pre-filled with the draft —
    /// the snapshot rides the route value); picking or Done completes
    /// through the Recents-tap contract, Back cancels restoring the draft.
    /// There is no inline field and no floating layer, so the Start action
    /// below can never be covered (issue #69).
    private var nameRow: some View {
        Button(action: onOpenNamePicker) {
            FieldCard {
                HStack(spacing: Theme.spacingSmall) {
                    Text(vm.nameDraft.isEmpty ? L10n.timerNamePlaceholder.text : vm.nameDraft)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(vm.nameDraft.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: Theme.minTapArea)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("TimerNameRow")
        .accessibilityLabel(L10n.timerNamePlaceholder.text)
        .accessibilityValue(vm.nameDraft)
        // The row resolves against the full name list, so it stays shut
        // until the first snapshot lands (steady-track-launch): a tap in
        // the pre-load window would open the picker on an empty list.
        .disabled(!vm.firstLoadSettled)
    }

    /// Running/error: the locked name card plus the standalone notes
    /// button outside it (separate-notes-editor, spike-approved): the
    /// card keeps the screen's leading alignment while the 44 pt button
    /// rides beside it at the screen's trailing padding, its tint
    /// signalling draft-notes presence. Tapping pushes the shared
    /// `NotesEditorPage` through the owning tab's path (fix-tab-bar-return-jump:
    /// a `ShellRoute` value prefilled from the running draft, so the
    /// stack-level tab-bar visibility observes the push; ✓ rewrites
    /// the draft snapshot, X discards). The row keeps standard insets,
    /// so every other row — including the main action — keeps its exact
    /// frame across states (D10).
    private var runningNameRow: some View {
        HStack(spacing: Theme.spacingSmall) {
            FieldCard {
                HStack(spacing: Theme.spacingSmall) {
                    Image(systemName: "timer")
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityHidden(true)
                    Text(vm.state.draft?.text ?? "")
                        .lineLimit(1)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: Theme.minTapArea)
            }
            Button(action: onOpenNotesEditor) {
                Image(systemName: "note.text")
                    .font(.title2)
                    .foregroundStyle(runningNotes.isEmpty ? Theme.textSecondary : Theme.accentPrimary)
                    .frame(minWidth: Theme.minTapArea, minHeight: Theme.minTapArea)
                    .contentShape(Rectangle())
                    .accessibilityLabel(L10n.entryNotesLabel.text)
                    .accessibilityValue(
                        runningNotes.isEmpty ? L10n.entryNotesPlaceholder.text : runningNotes
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("RunningNotesButton")
        }
    }

    /// The running draft's notes, empty when not recording.
    private var runningNotes: String {
        vm.state.draft?.notes ?? ""
    }

    private var lockedNameLabel: some View {
        FieldCard {
            HStack(spacing: Theme.spacingSmall) {
                Image(systemName: "timer")
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                Text(vm.state.draft?.text ?? "")
                    .lineLimit(1)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .font(.body)
            .frame(maxWidth: .infinity, minHeight: Theme.minTapArea)
        }
        .accessibilityIdentifier("TimerNameLabel")
        .accessibilityLabel(vm.state.draft?.text ?? "")
    }

    // MARK: - Running TagSelector (remove-activities-layer 4.2)

    /// The shared ordered TagSelector (select-only from existing categories,
    /// zero allowed, order preserved). Toggles rewrite only the running
    /// draft snapshot. Always mounted — even when idle with an empty
    /// selection — so its height never changes on state switch: the rows
    /// depend only on the category options, never on the selection, which
    /// keeps the below-button slot (and everything above it) pixel-stable.
    /// Visibility is opacity-only (see `belowActionSlot`).
    private var runningTagSelector: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSmall) {
            Text(L10n.entryCategoriesLabel.text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Divider().background(Theme.hairline)
            TagSelector(
                options: Array(vm.categories.values).sorted { $0.name < $1.name },
                selected: runningSelectedIDs,
                onToggle: { toggledID in
                    vm.toggleDraftCategory(toggledID)
                },
                accessibilityId: "RunningTags"
            )
        }
        .accessibilityIdentifier("RunningTagSelector")
    }

    /// The running draft's ordered selection while running, empty otherwise.
    /// Selection never affects the selector's geometry (rows come from the
    /// options alone).
    private var runningSelectedIDs: [String] {
        if case let .running(draft, _) = vm.state {
            draft.categoryIDs
        } else {
            []
        }
    }

    // MARK: - Primary action

    private var primaryAction: some View {
        PrimaryButton(
            title: primaryTitle,
            icon: primaryIcon,
            isLoading: vm.state.isSaving,
            isDisabled: primaryDisabled,
            accessibilityId: primaryIdentifier,
            tint: vm.state.isRunning ? Theme.danger : nil,
            animateStateChanges: false
        ) {
            switch vm.state {
            case .idle, .ready, .saved:
                // Naming happens on the picker page (its keyboard dismisses
                // on pop), so Start never competes with a keyboard slide and
                // fires directly.
                vm.start()
            case .running, .saving:
                Task { await vm.stop() }
            case .error:
                Task { await vm.retryStop() }
            }
        }
        .frame(height: actionSlotHeight)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: MainActionSlotWidthKey.self,
                    value: geometry.size.width
                )
            }
        )
        .accessibilityHint(primaryHint)
    }

    /// D10: the fixed-height slot for the state-specific main action. The
    /// slot equals the tallest title presentation at the active Dynamic
    /// Type size, so the Start / Stop swap never resizes or moves the
    /// control.
    private var actionSlotHeight: CGFloat {
        MainActionSlot.height(
            titles: primaryTitles,
            width: actionSlotWidth,
            at: dynamicTypeSize
        )
    }

    private var primaryTitles: [String] {
        [L10n.timerStart.text, L10n.timerStop.text]
    }

    private var primaryTitle: String {
        switch vm.state {
        case .idle, .ready, .saved: L10n.timerStart.text
        case .running, .saving, .error: L10n.timerStop.text
        }
    }

    private var primaryIcon: String? {
        switch vm.state {
        case .idle, .ready, .saved: "play.fill"
        case .running, .saving, .error: "stop.fill"
        }
    }

    private var primaryDisabled: Bool {
        switch vm.state {
        case .idle, .ready: !vm.canStart
        case .saved, .saving: true
        case .running, .error: false
        }
    }

    private var primaryIdentifier: String {
        switch vm.state {
        case .idle, .ready, .saved: "TimerStartButton"
        case .running, .saving, .error: "TimerStopButton"
        }
    }

    private var primaryHint: String {
        switch vm.state {
        case .running, .saving, .error: L10n.timerStopHint.text
        default: ""
        }
    }

    // MARK: - Recent activities

    /// Recents while idle (the running tag selector takes this slot while
    /// running, see `belowActionSlot`).
    private var recentActivities: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSmall) {
            Text(L10n.timerChooserRecent.text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Divider().background(Theme.hairline)

            if vm.recents.isEmpty {
                Text(L10n.timerRecentsEmptyHint.text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                RecentActivitiesChips(
                    recents: vm.recents,
                    categories: vm.categories,
                    selectedText: vm.state.draft?.text
                ) { vm.select($0) }
            }
        }
    }
}

private struct MainActionSlotWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TrackErrorRegionHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
