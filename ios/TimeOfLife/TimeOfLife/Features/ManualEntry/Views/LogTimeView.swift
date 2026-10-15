// Follow-up (#57): Split this view (card sections/pickers → subviews) to get
// under the 400-line file_length limit and drop this suppression. (A scoped
// `:next` disable cannot cover file_length — the violation is reported at
// EOF — so the suppression stays file-wide with this tracking reference.)
// swiftlint:disable file_length
import SwiftUI

/// The unified entry form (entry-editor spec + manual-entry CREATE mode),
/// styled on the iOS Calendar add-event form and trimmed to five cards in
/// fixed order: Name, Start, End, Categories, Notes (Start/End are separate
/// cards, each with date + time pills and an inline single-open picker).
/// X/checkmark (CREATE sheet) or Back/checkmark (pushed EDIT, fix-50-nav-buttons
/// Calendar grammar) live in the navigation bar; the
/// confirm action is a validity gate — disabled until the trimmed name is
/// non-empty and End is strictly after Start. LOCKED mode shows the values
/// read-only with Back only (no dismiss text button, no confirm); EDIT and LOCKED
/// Delete. A save failure surfaces as a non-field error with the draft
/// intact and the form open.
///
/// Gesture rule (fix-entry-form-gestures): no system gesture is ever
/// disabled here — the wheel pickers keep non-picker grab area around them
/// so pull-down-to-scroll always reaches the outer ScrollView, and the
/// pushed (EDIT/LOCKED) presentation provides the edge-back gesture.
/// Tap-away keyboard dismissal stays wired through the shared `FormCard`
/// container as a plain tap, but no inline text field remains on this form
/// (name is a push row; notes editing lives on the pushed `NotesEditorPage`
/// with X/✓ chrome and no keyboard Done key), so every resign is currently
/// a no-op kept for the next inline field: child buttons still consume
/// their taps, and chips/pills still resign explicitly in their actions.
struct LogTimeView: View {
    @StateObject private var vm: LogTimeViewModel
    @EnvironmentObject var container: AppContainer
    @Environment(\.dismiss)
    private var dismiss
    /// The currently expanded inline picker, if any (Calendar behavior:
    /// one open at a time; tapping the active pill collapses it).
    @State private var expandedPicker: InlinePicker?
    /// Drives the delete confirmation alert (EDIT + LOCKED modes).
    @State private var isShowingDeleteConfirm = false
    /// The text field holding focus, if any (tap-away/scroll-away resigns it).
    @FocusState private var focusedField: FormField?
    /// True when pushed onto the presenter's NavigationStack (EDIT/LOCKED
    /// via History) instead of presented as a sheet (CREATE): the outer
    /// stack owns the navigation chrome AND the back stack (edge-back
    /// gesture), so the internal NavigationStack is skipped — never nested.
    private let embeddedInNavigationStack: Bool
    /// Called after a successful save so the presenter can refresh.
    let onSaved: (() -> Void)?

    /// The form's text field (focus-tracked for tap-away dismissal).
    private enum FormField {
        case notes
    }

    private enum InlinePicker {
        case startDate, startTime, endDate, endTime
    }

    init(
        service: TimerService,
        initialText: String = "",
        initialCategoryIDs: [String] = [],
        editing entry: TimeEntry? = nil,
        embeddedInNavigationStack: Bool = false,
        onSaved: (() -> Void)? = nil
    ) {
        _vm = StateObject(wrappedValue: LogTimeViewModel(
            service: service,
            initialText: initialText,
            initialCategoryIDs: initialCategoryIDs,
            editing: entry
        ))
        self.embeddedInNavigationStack = embeddedInNavigationStack
        self.onSaved = onSaved
    }

    var body: some View {
        if embeddedInNavigationStack {
            chrome(formContent)
        } else {
            NavigationStack {
                chrome(formContent)
            }
        }
    }

    /// The scrollable card stack (shared by the sheet and pushed forms so
    /// CREATE and EDIT can never visually diverge).
    private var formContent: some View {
        ScrollView {
            VStack(spacing: Theme.spacingMedium) {
                nameCard
                    .disabled(vm.isLocked)
                    .opacity(vm.isLocked ? Theme.opacityLockedForm : 1)
                startCard
                    .disabled(vm.isLocked)
                    .opacity(vm.isLocked ? Theme.opacityLockedForm : 1)
                endCard
                    .disabled(vm.isLocked)
                    .opacity(vm.isLocked ? Theme.opacityLockedForm : 1)
                categoriesCard
                    .disabled(vm.isLocked)
                    .opacity(vm.isLocked ? Theme.opacityLockedForm : 1)
                notesCard
                    .disabled(vm.isLocked)
                    .opacity(vm.isLocked ? Theme.opacityLockedForm : 1)
                if vm.isLocked {
                    lockedNote
                }
                if vm.errorMessage != nil {
                    errorSection
                }
                if vm.mode != .create {
                    deleteSection
                }
            }
            .padding(.horizontal, Theme.spacingMedium)
            .padding(.vertical, Theme.spacingMedium)
        }
        .background(Theme.backgroundPrimary.ignoresSafeArea())
        // Scroll-away dismisses the keyboard (native interactive behavior).
        .scrollDismissesKeyboard(.interactively)
    }

    /// The navigation chrome shared by both presentations: title +
    /// duration subtitle, bar actions, delete confirmation, and data loads.
    @ViewBuilder
    private func chrome<Content: View>(_ content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            // Pushed EDIT/LOCKED forms hide the tab bar through the owning
            // History stack's path-driven visibility
            // (fix-tab-bar-return-jump) — this chrome declares nothing, so
            // pop restores the bar in the same pass. The CREATE sheet has
            // no tab bar either way.
            .toolbar {
                ToolbarItem(placement: .principal) {
                    titleSubtitle
                }
                // Calendar grammar (fix-50-nav-buttons): the pushed form
                // (EDIT/LOCKED) dismisses via the system Back button, so no
                // leading dismiss item is shown there; the CREATE sheet (no
                // back stack) dismisses via an X button with the same action.
                EditorToolbar(
                    showsDismiss: !embeddedInNavigationStack,
                    dismissAccessibilityLabel: L10n.entryDismissLabel.text,
                    dismissAccessibilityId: "LogTimeDismissButton",
                    isDismissDisabled: false,
                    onDismiss: dismiss(),
                    showsConfirm: !vm.isLocked,
                    confirmAccessibilityLabel: vm.mode == .edit
                        ? L10n.entryConfirmSaveLabel.text
                        : L10n.entryConfirmAddLabel.text,
                    confirmAccessibilityId: vm.mode == .edit ? "EntryEditSaveButton" : "LogTimeAddButton",
                    isConfirmDisabled: !vm.isAddEnabled
                ) {
                    Task { await save() }
                }
            }
            .alert(
                L10n.entryDeleteTitle.text,
                isPresented: $isShowingDeleteConfirm
            ) {
                Button(L10n.entryDeleteConfirm.text, role: .destructive) {
                    Task { await deleteEntry() }
                }
                Button(L10n.logTimeCancel.text, role: .cancel) {}
            } message: {
                Text(L10n.entryDeleteMessage.text)
            }
            .task {
                await vm.loadCategoriesIfNeeded(store: container.localStore)
                await vm.loadNameRecentsIfNeeded(store: container.localStore)
            }
    }

    /// Live duration subtitle in the nav bar (feat-entry-duration-subtitle):
    /// the mode title plus a footnote line — the natural-language interval
    /// duration while End is after Start, or the invalid-interval
    /// explanation in red (the confirm is disabled) otherwise. Display-only
    /// over the already-published `startsAt`/`endsAt`.
    private var titleSubtitle: some View {
        VStack(spacing: 0) {
            Text(formTitle)
                .font(.headline)
                .lineLimit(1)
            if let seconds = vm.durationSubtitleSeconds {
                Text(String(
                    format: L10n.entryDuration.text,
                    locale: .current,
                    HistoryViewModel.naturalDuration(seconds)
                ))
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            } else {
                Text(L10n.entryInvalidInterval.text)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("EntryDurationSubtitle")
    }

    /// Mode-specific navigation title (localized).
    private var formTitle: String {
        switch vm.mode {
        case .create: L10n.logTimeTitle.text
        case .edit: L10n.entryEditTitle.text
        case .locked: L10n.entryLockedTitle.text
        }
    }

    private func save() async {
        if await vm.save() {
            onSaved?()
            dismiss()
        }
    }

    /// Deletes the entry into the durable undo buffer; dismisses on success
    /// (the presenter reloads via the push/sheet dismissal). On failure the
    /// form stays open with the error banner.
    private func deleteEntry() async {
        if await vm.deleteConfirmed() {
            dismiss()
        }
    }

    // MARK: - Name row

    private var nameCard: some View {
        FormCard(accessibilityID: "EntryNameRow", resignFocus: focusedField = nil) {
            VStack(alignment: .leading, spacing: Theme.spacingExtraSmall) {
                HStack(spacing: Theme.spacingSmall) {
                    Text(L10n.entryNameLabel.text)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    // No chevron in LOCKED mode: the row offers no
                    // navigation there, so the affordance would mislead.
                    if !vm.isLocked {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .accessibilityHidden(true)
                    }
                }
                if vm.isLocked {
                    Text(vm.name)
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: Theme.minTapArea)
                } else {
                    NavigationLink {
                        NamePicker(
                            initialText: vm.name,
                            recents: vm.nameRecents,
                            categories: Dictionary(uniqueKeysWithValues: vm.availableCategories.map { ($0.id, $0) }),
                            placeholder: L10n.entryNamePlaceholder.text,
                            emptyHint: L10n.timerRecentsEmptyHint.text,
                            onCompleteSuggestion: {
                                vm.applySuggestion(text: $0.text, categoryIDs: $0.categoryIDs)
                            },
                            onCompleteText: { vm.completeTypedName($0) }
                        )
                    } label: {
                        HStack(spacing: Theme.spacingSmall) {
                            Text(vm.name.isEmpty ? L10n.entryNamePlaceholder.text : vm.name)
                                .font(.body)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(vm.name.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: Theme.minTapArea)
                        .contentShape(Rectangle())
                    }
                    // No resign here (issue #67): the pushed NamePicker
                    // autofocuses its own field, so focus transfers directly
                    // and the keyboard never drops — resigning first would
                    // replay the dismiss/reappear flicker this change kills.
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.entryNameLabel.text)
                    .accessibilityValue(vm.name)
                }
            }
        }
    }

    // MARK: - Categories row

    private var categoriesCard: some View {
        FormCard(accessibilityID: "EntryCategoriesRow", resignFocus: focusedField = nil) {
            VStack(alignment: .leading, spacing: Theme.spacingExtraSmall) {
                Text(L10n.entryCategoriesLabel.text)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                TagSelector(
                    options: vm.availableCategories,
                    selected: vm.categoryIDs,
                    onToggle: {
                        vm.toggleCategory($0)
                        // The plain card tap-away stays silent on chip taps
                        // (consumed), so toggles resign explicitly here.
                        focusedField = nil
                    },
                    accessibilityId: "EntryCategories"
                )
            }
        }
    }

    // MARK: - Notes row (presenter + pushed editor, separate-notes-editor)

    /// Read-only Notes presenter (approved spike variant B): a caption row
    /// with a corner-balanced trailing chevron plus full-width 1–5 line
    /// text with truncation, placeholder when empty. Tapping pushes the
    /// shared `NotesEditorPage` (copy-on-open: X discards, ✓ writes
    /// `vm.notes` only and the validity gate re-evaluates). LOCKED mode
    /// renders the same presenter read-only with no navigation.
    private var notesCard: some View {
        FormCard(accessibilityID: "EntryNotesRow", resignFocus: focusedField = nil) {
            if vm.isLocked {
                VStack(alignment: .leading, spacing: Theme.spacingExtraSmall) {
                    Text(L10n.entryNotesLabel.text)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text(vm.notes.isEmpty ? L10n.entryNotesPlaceholder.text : vm.notes)
                        .font(.body)
                        .lineLimit(1...5)
                        .foregroundStyle(vm.notes.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                NavigationLink {
                    NotesEditorPage(initialText: vm.notes, entryName: vm.name) { vm.notes = $0 }
                } label: {
                    VStack(alignment: .leading, spacing: Theme.spacingExtraSmall) {
                        HStack(spacing: Theme.spacingSmall) {
                            Text(L10n.entryNotesLabel.text)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .accessibilityHidden(true)
                        }
                        Text(vm.notes.isEmpty ? L10n.entryNotesPlaceholder.text : vm.notes)
                            .font(.body)
                            .lineLimit(1...5)
                            .foregroundStyle(vm.notes.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: Theme.minTapArea, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.entryNotesLabel.text)
                .accessibilityValue(vm.notes.isEmpty ? L10n.entryNotesPlaceholder.text : vm.notes)
            }
        }
    }

    // MARK: - Locked provenance note

    /// Read-only note for imported entries (LOCKED mode): bare source name
    /// plus why editing is disabled.
    private var lockedNote: some View {
        HStack(spacing: Theme.spacingExtraSmall) {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text(String(
                format: L10n.entryLockedNote.text,
                locale: .current,
                EntryProvenance.name(for: vm.editingEntry?.source ?? "manual")
            ))
        }
        .font(.caption)
        .foregroundStyle(Theme.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.spacingMedium)
        .background(Theme.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .accessibilityIdentifier("EntryLockedNote")
    }

    // MARK: - Delete

    /// Bottom-of-page destructive Delete (EDIT + LOCKED modes only).
    private var deleteSection: some View {
        DestructiveBottomButton(
            title: L10n.entryDelete.text,
            accessibilityId: "EntryDeleteButton"
        ) {
            isShowingDeleteConfirm = true
        }
    }

    // MARK: - Start / End cards

    /// Separate cards (not one combined card): each picker's vertical-drag
    /// capture area stays small with non-picker grab surfaces adjacent, so a
    /// scroll drag starting outside the wheels always reaches the outer
    /// ScrollView. No gesture is disabled to achieve this.
    private var startCard: some View {
        FormCard(resignFocus: focusedField = nil) {
            VStack(alignment: .leading, spacing: Theme.spacingSmall) {
                timeRow(
                    title: L10n.logTimeStarts.text,
                    date: vm.startsAt,
                    datePicker: .startDate,
                    timePicker: .startTime,
                    dateId: "LogTimeStartDatePill",
                    timeId: "LogTimeStartTimePill"
                )
            }
        }
    }

    private var endCard: some View {
        FormCard(resignFocus: focusedField = nil) {
            VStack(alignment: .leading, spacing: Theme.spacingSmall) {
                timeRow(
                    title: L10n.logTimeEnds.text,
                    date: vm.endsAt,
                    datePicker: .endDate,
                    timePicker: .endTime,
                    dateId: "LogTimeEndDatePill",
                    timeId: "LogTimeEndTimePill"
                )
            }
        }
    }

    private func timeRow(
        title: String,
        date: Date,
        datePicker: InlinePicker,
        timePicker: InlinePicker,
        dateId: String,
        timeId: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingExtraSmall) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            HStack(spacing: Theme.spacingSmall) {
                pill(Self.dateText(for: date), active: expandedPicker == datePicker, id: dateId) {
                    toggle(datePicker)
                }
                pill(HistoryViewModel.timeText(for: date), active: expandedPicker == timePicker, id: timeId) {
                    toggle(timePicker)
                }
            }
            // Pills must switch highlight instantly — otherwise the capsule
            // background lags behind the text when the picker change animates.
            .animation(.none, value: expandedPicker)
            // Both pickers stay mounted and collapse to zero height instead of
            // conditional insertion: the graphical calendar renders
            // asynchronously on first layout, and mounting it on expand
            // flashes an empty card before the month grid pops in
            // (size-jump). Pre-mounted pickers grow smoothly with the height
            // animation, and the fixed container height keeps every month
            // (4-6 weeks) the same size. Collapsed pickers are disabled,
            // hidden from accessibility, and clipped to zero height so they
            // take no space and intercept no touches.
            VStack(spacing: 0) {
                DatePicker(
                    "",
                    selection: dateBinding(for: datePicker),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                // FB9614392 workaround: a parent TapGesture (the FormCard
                // background tap-away) steals the calendar's header-button
                // touches (month steppers) even from the background layer.
                // An unfulfillable tap count on the picker itself restores
                // the calendar's internal gesture precedence without ever
                // firing; day cells already win without it, steppers need it.
                .onTapGesture(count: 99) {}
                .frame(maxWidth: .infinity)
                .frame(height: expandedPicker == datePicker ? Self.graphicalPickerHeight : 0)
                .opacity(expandedPicker == datePicker ? 1 : 0)
                .disabled(expandedPicker != datePicker)
                .accessibilityHidden(expandedPicker != datePicker)
                .clipped()
                DatePicker(
                    "",
                    selection: dateBinding(for: timePicker),
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .frame(height: expandedPicker == timePicker ? Self.wheelPickerHeight : 0)
                .opacity(expandedPicker == timePicker ? 1 : 0)
                .disabled(expandedPicker != timePicker)
                .accessibilityHidden(expandedPicker != timePicker)
                .clipped()
            }
            // Only the picker container animates; pills above stay instant.
            .animation(.easeInOut(duration: 0.2), value: expandedPicker)
        }
        // Full card width (fix-51-picker-width): without this the collapsed
        // card hugs its pills — the outer form stack is center-aligned, so
        // a hugging card centers instead of stretching margin-to-margin
        // like the other editors. Expanded pickers already take all offered
        // width, so this only stabilizes them (no collapsed↔expanded jump).
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pill(_ text: String, active: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.callout)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, Theme.spacingSmall + 4)
                .padding(.vertical, Theme.spacingSmall - 2)
                .foregroundStyle(active ? Theme.accentPrimary : Theme.textPrimary)
                .background(active ? Theme.accentPrimary.opacity(Theme.opacityAccentSoft) : Theme.backgroundPrimary)
                .clipShape(Capsule())
        }
        .accessibilityIdentifier(id)
        // Belt-and-braces: never animate the highlight itself, even if a
        // parent transaction carries an animation.
        .transaction { $0.disablesAnimations = true }
    }

    private func toggle(_ picker: InlinePicker) {
        expandedPicker = (expandedPicker == picker) ? nil : picker
        // The plain card tap-away stays silent on pill taps (consumed), so
        // expanding/collapsing a picker resigns explicitly here.
        focusedField = nil
    }

    private func dateBinding(for picker: InlinePicker) -> Binding<Date> {
        Binding(
            get: {
                switch picker {
                case .startDate, .startTime: vm.startsAt
                case .endDate, .endTime: vm.endsAt
                }
            },
            set: {
                switch picker {
                case .startDate, .startTime: vm.setStartsAt($0)
                case .endDate, .endTime: vm.setEndsAt($0)
                }
            }
        )
    }

    // MARK: - Error

    private var errorSection: some View {
        Group {
            if let errorMessage = vm.errorMessage {
                ErrorBanner(
                    message: errorMessage,
                    accessibilityId: "LogTimeErrorBanner"
                )
            }
        }
    }

    // MARK: - Formatting

    /// Fixed wheel-picker height (standard `UIPickerView` height): the
    /// GeometryReader container needs an explicit height.
    private static let wheelPickerHeight: CGFloat = 216
    /// Fixed calendar-picker height: large enough for six-week months
    /// without clipping.
    private static let graphicalPickerHeight: CGFloat = 360

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static func dateText(for date: Date) -> String {
        dateFormatter.string(from: date)
    }
}

#if DEBUG
#Preview("Log Time — Empty") {
    let container = AppContainer.production()
    LogTimeView(service: container.timerService)
        .environmentObject(container)
}
#endif
