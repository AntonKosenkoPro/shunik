import Combine
import Foundation
import SwiftUI

/// Presentation mode of the unified entry form (entry-editor spec): CREATE
/// logs new time (manual-entry behavior, unchanged); EDIT corrects an
/// existing `manual` entry; LOCKED shows an imported entry read-only with
/// delete as the only mutation.
enum EntryFormMode: Equatable, Sendable {
    case create
    case edit
    case locked
}

/// View model for the Log Time sheet (manual-entry spec) grown into the
/// unified entry form (entry-editor spec): a validated name + categories +
/// notes + start/end draft that saves a committed manual entry in CREATE
/// mode, updates an existing `manual` entry in EDIT mode, or exposes an
/// imported entry read-only in LOCKED mode.
///
/// The draft is fully local: Start defaults to now floored to 5 minutes,
/// End to Start + 1h. Moving Start shifts End by the same delta so the
/// duration stays constant, whether Start moves earlier or later; moving
/// End never moves Start. Add/Save is a validity gate (`isAddEnabled`):
/// the trimmed name must be non-empty and the interval must satisfy the
/// floor rule — untouched prefills keep the legacy end-after-start rule
/// (grandfathered sub-minute drafts stay savable), edited drafts require
/// end at least one minute after start. There is no
/// activity re-resolve — entries own their text (remove-activities-layer).
/// Persistence delegates to `TimerService`'s store (`LocalStore.createEntry`
/// + transactional outbox for CREATE, LWW `LocalStore.updateEntry` for
/// EDIT); overlaps and future end-times are allowed, matching store
/// semantics.
@MainActor
final class LogTimeViewModel: ObservableObject {
    /// Default duration for a fresh sheet and the fallback when the
    /// previous duration is unknown or invalid.
    static let defaultDuration: TimeInterval = 3_600
    /// Start-time flooring granularity, in minutes.
    static let startGranularityMinutes = 5
    /// Minimum allowed duration for a manually edited interval, in seconds.
    static let minimumDuration: TimeInterval = 60

    @Published var name: String
    /// The ordered category selection (TagSelector parent owns order).
    @Published private(set) var categoryIDs: [String]
    /// The full category catalog for the TagSelector options, loaded once
    /// on open.
    @Published private(set) var availableCategories: [Category] = []
    /// Every committed entry text for the shared name picker
    /// (dedicated-name-picker), loaded once on open. Newest-first, uncapped —
    /// the picker suggests all names ever used, not just the chip cap.
    /// Settable (not `private(set)`) so tests can seed names directly
    /// instead of driving them through async store paths.
    @Published var nameRecents: [ExactName] = []
    @Published var notes: String
    @Published private(set) var startsAt: Date
    @Published private(set) var endsAt: Date
    @Published var errorMessage: String?
    /// The entry being corrected in EDIT mode or shown in LOCKED mode
    /// (nil in CREATE mode).
    @Published private(set) var editingEntry: TimeEntry?

    /// True once the user has written through any Start/End picker. Flips
    /// only in the time-picker setters — name/category/notes edits never
    /// touch it. Distinguishes fresh picks (floor-enforced) from untouched
    /// legacy prefills (grandfathered).
    @Published private(set) var timesTouched = false

    let service: TimerService

    /// The form mode, derived from the edited entry: no entry is CREATE, a
    /// `manual` entry is EDIT, any other source is LOCKED (entry-editor
    /// spec). Pure so the mode routing is unit-testable.
    static func mode(for entry: TimeEntry?) -> EntryFormMode {
        guard let entry else { return .create }
        return entry.source == "manual" ? .edit : .locked
    }

    /// The mode of this form instance.
    var mode: EntryFormMode { Self.mode(for: editingEntry) }

    /// True in LOCKED mode: all inputs are disabled and no confirm action
    /// exists (delete stays available).
    var isLocked: Bool { mode == .locked }

    init(
        service: TimerService,
        initialText: String = "",
        initialCategoryIDs: [String] = [],
        editing entry: TimeEntry? = nil,
        now: Date = Date()
    ) {
        self.service = service
        self.editingEntry = entry
        if let entry {
            // EDIT/LOCKED prefill straight from the entry's own fields —
            // there is no activity to re-resolve. The form never receives an
            // in-progress entry (no entry point lists one); a nil end falls
            // back to the default duration defensively.
            self.name = entry.activityText
            self.categoryIDs = entry.categoryIDs
            self.notes = entry.notes
            self.startsAt = entry.startedAt
            self.endsAt = entry.endedAt ?? entry.startedAt.addingTimeInterval(Self.defaultDuration)
        } else {
            let start = Self.floored(now)
            self.name = initialText
            self.categoryIDs = initialCategoryIDs
            self.notes = ""
            self.startsAt = start
            self.endsAt = start.addingTimeInterval(Self.defaultDuration)
        }
    }

    /// The trimmed name.
    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the trimmed name is non-empty and the interval satisfies
    /// the floor rule (see `isIntervalValid`).
    var isAddEnabled: Bool {
        !trimmedName.isEmpty && isIntervalValid
    }

    /// Interval part of the validity gate: untouched prefills use the
    /// legacy end-strictly-after-start rule (grandfathered sub-minute
    /// drafts stay savable); manually edited drafts require the end at
    /// least one minute after the start.
    private var isIntervalValid: Bool {
        let interval = endsAt.timeIntervalSince(startsAt)
        return timesTouched ? interval >= Self.minimumDuration : interval > 0
    }

    /// Rounded Start→End seconds for the nav-bar duration subtitle: the
    /// true draft duration (a grandfathered untouched draft shows its real
    /// sub-minute value, e.g. 33s). Nil when the interval disables the
    /// confirm action. Pure display helper — the validity gate and save
    /// paths are unchanged.
    var durationSubtitleSeconds: Int? {
        guard isIntervalValid else { return nil }
        return max(0, Int(endsAt.timeIntervalSince(startsAt).rounded()))
    }

    /// Display Start for pills and picker selections: minute-exact. The
    /// minute wheels cannot show seconds, so untouched drafts render (and
    /// adopt) the minute floor; touched drafts are minute-exact already,
    /// making the floor an identity.
    var displayStartsAt: Date {
        Self.floored(startsAt, toMinutes: 1)
    }

    /// Display End for pills and picker selections: floored Start plus one
    /// minute for untouched sub-minute drafts (flooring both ends there
    /// would collapse, e.g. 0:00:15–0:00:25 to the invalid 0:00–0:00 pair);
    /// the minute floor otherwise (identity once minute-exact).
    var displayEndsAt: Date {
        isGrandfathered ? displayStartsAt.addingTimeInterval(Self.minimumDuration) : Self.floored(endsAt, toMinutes: 1)
    }

    /// Loads the category catalog for the TagSelector (idempotent). Called
    /// on open by the view.
    func loadCategoriesIfNeeded(store: LocalStore) async {
        guard availableCategories.isEmpty else { return }
        availableCategories = (try? await store.categories()) ?? []
    }

    /// Loads every committed entry text for the name picker (idempotent).
    /// A failure leaves suggestions empty — it never blocks the form.
    /// Called on open by the view alongside the catalog load.
    func loadNameRecentsIfNeeded(store: LocalStore) async {
        guard nameRecents.isEmpty else { return }
        nameRecents = (try? await store.allActivityNames().map(ExactName.init(storeRecent:))) ?? []
    }

    /// Fills the draft from an autocomplete suggestion (the Recents tap
    /// contract): exact text plus that entry's full ordered categories.
    /// Draft-only — no committed entry is touched and validation/save
    /// behavior is unchanged.
    func applySuggestion(text: String, categoryIDs: [String]) {
        name = text
        self.categoryIDs = categoryIDs
    }

    /// Completes the picker with typed text (name-picker spec): an
    /// exact-recent match inherits that entry's ordered categories (the
    /// Recents-tap contract); any other non-empty text keeps the caller's
    /// current categories (e.g. chosen in the TagSelector). Empty input is
    /// a no-op — Back remains the exit. Draft-only, like `applySuggestion`.
    func completeTypedName(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let match = nameRecents.first(where: { $0.text == trimmed }) {
            applySuggestion(text: match.text, categoryIDs: match.categoryIDs)
        } else {
            name = trimmed
        }
    }

    /// Toggles a category on the ordered selection (TagSelector parent owns
    /// order: toggling appends or removes, keeping the selection order).
    func toggleCategory(_ categoryID: String) {
        if let index = categoryIDs.firstIndex(of: categoryID) {
            categoryIDs.remove(at: index)
        } else {
            categoryIDs.append(categoryID)
        }
    }

    /// Moves Start, shifting End by the same delta so the duration stays
    /// constant — whether Start moves earlier or later. The first write on
    /// an untouched draft adopts the minute-normalized display values, then
    /// the gesture applies on top. The incoming value is minute-floored as
    /// well (date pickers preserve seconds; wheels are already exact), so a
    /// touched draft is minute-exact by construction.
    func setStartsAt(_ newStart: Date) {
        adoptDisplayValuesIfNeeded()
        timesTouched = true
        let flooredNew = Self.floored(newStart, toMinutes: 1)
        let delta = flooredNew.timeIntervalSince(startsAt)
        startsAt = flooredNew
        endsAt = endsAt.addingTimeInterval(delta)
    }

    /// Moves End. Never moves Start. The first write on an untouched draft
    /// adopts the minute-normalized display values first; the incoming
    /// value is minute-floored as well (see `setStartsAt`).
    func setEndsAt(_ newEnd: Date) {
        adoptDisplayValuesIfNeeded()
        timesTouched = true
        endsAt = Self.floored(newEnd, toMinutes: 1)
    }

    /// Saves the draft: a committed manual entry in CREATE mode, a
    /// last-write-wins update in EDIT mode. Returns false (with
    /// `errorMessage` set and the draft intact) when the form is invalid,
    /// persistence fails, or (EDIT) the record changed underneath (stale
    /// write). LOCKED mode has no confirm path and always returns false.
    func save() async -> Bool {
        guard mode != .locked else { return false }
        guard !trimmedName.isEmpty, isIntervalValid else { return false }
        do {
            if let editing = editingEntry, mode == .edit {
                let updated = TimeEntry(
                    id: editing.id,
                    activityText: trimmedName,
                    startedAt: startsAt,
                    endedAt: endsAt,
                    durationSeconds: max(0, Int(endsAt.timeIntervalSince(startsAt))),
                    source: editing.source,
                    sourceRef: editing.sourceRef,
                    categoryIDs: categoryIDs,
                    notes: notes,
                    createdAt: editing.createdAt,
                    updatedAt: Date()
                )
                guard try await service.store.updateEntry(updated) else {
                    // Lost the last-write-wins race (e.g. a sync pull landed
                    // a newer version): keep the draft, stay open.
                    errorMessage = L10n.entryStaleError.text
                    return false
                }
                return true
            }
            let entry = TimeEntry(
                id: await service.store.newRecordID(),
                activityText: trimmedName,
                startedAt: startsAt,
                endedAt: endsAt,
                durationSeconds: max(0, Int(endsAt.timeIntervalSince(startsAt))),
                source: "manual",
                categoryIDs: categoryIDs,
                notes: notes
            )
            try await service.store.createEntry(entry)
            return true
        } catch {
            errorMessage = L10n.text(in: .default, code: "error.unknown")
            return false
        }
    }

    /// Deletes the edited entry (EDIT + LOCKED modes) into the durable undo
    /// buffer (no outbox row yet — shake-to-undo restores it; expiry commits
    /// on foreground). Returns true when the caller should dismiss the form
    /// (deleted, or already gone elsewhere); false keeps the form open with
    /// `errorMessage` set.
    func deleteConfirmed() async -> Bool {
        guard let editing = editingEntry, mode != .create else { return false }
        do {
            switch try await service.store.deleteEntryUndoable(id: editing.id) {
            case .deleted:
                return true
            case .missing:
                // Already gone elsewhere — the desired end state holds.
                return true
            case .failure:
                errorMessage = L10n.errorLocalPersistence.text
                return false
            }
        } catch {
            errorMessage = L10n.errorLocalPersistence.text
            return false
        }
    }

    // MARK: - Helpers

    /// True for an untouched prefill shorter than one minute (but still
    /// positive): backing times stay original until a picker is touched.
    /// A prefill with end at or before start keeps the invalid path.
    private var isGrandfathered: Bool {
        !timesTouched && endsAt > startsAt
            && endsAt.timeIntervalSince(startsAt) < Self.minimumDuration
    }

    /// First write through any time picker minute-normalizes the pair
    /// (floor both ends — e.g. 23:59:34–00:01:58 becomes 23:59–00:01 — so
    /// the wheels never hold seconds they cannot display), then the gesture
    /// applies on top. Snapshot before assigning: both mapped values must
    /// derive from the same pre-touch state. For drafts of at least one
    /// minute the floored pair is provably still at least one minute
    /// (duration ≡ endSecs−startSecs mod 60, so flooring lands on a minute
    /// multiple ≥ 60s); sub-minute drafts land on exactly one minute.
    /// No-op once touched — and a no-op by construction for minute-exact
    /// drafts (CREATE defaults, already-touched drafts).
    private func adoptDisplayValuesIfNeeded() {
        guard !timesTouched else { return }
        let mappedStart = displayStartsAt
        let mappedEnd = displayEndsAt
        startsAt = mappedStart
        endsAt = mappedEnd
    }

    /// Selectable End-date range: no day before the Start day. Nil when the
    /// current End selection would fall below the bound (only reachable
    /// with a corrupt end-before-start prefill) — an unbounded picker plus
    /// the disabled gate beats a clamped selection there.
    var endDateRange: ClosedRange<Date>? {
        let lower = Calendar.current.startOfDay(for: displayStartsAt)
        guard displayEndsAt >= lower else { return nil }
        return lower...Date.distantFuture
    }

    /// Selectable End-time range, derived from the minute-exact display
    /// Start so the selection (`displayEndsAt`) always lies inside: from
    /// `displayStartsAt + 60s` when End shares the Start day, the whole End
    /// day otherwise (any time on a later day already exceeds the floor).
    /// Same-day degenerate case (no valid same-day End exists, or a
    /// corrupt end-before-start selection) falls back to the full End day
    /// with the gate as enforcer, instead of risking an inverted range or
    /// an out-of-range selection.
    var endTimeRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let endDay = calendar.startOfDay(for: displayEndsAt)
        let endDayEnd = (calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay.addingTimeInterval(86_400))
            .addingTimeInterval(-1)
        guard calendar.isDate(displayEndsAt, inSameDayAs: displayStartsAt) else {
            return endDay...endDayEnd
        }
        let lower = Self.ceiledToMinute(displayStartsAt.addingTimeInterval(Self.minimumDuration))
        guard lower <= endDayEnd, displayEndsAt >= lower else { return endDay...endDayEnd }
        return lower...endDayEnd
    }

    /// Ceils a date up to the minute boundary (minute-exact inputs stay
    /// exact: Double division of an integral-second interval by 60 is
    /// exact, so no epsilon is needed). Used for the same-day End time
    /// picker bound: the smallest minute cell at least one minute after
    /// Start.
    static func ceiledToMinute(_ date: Date) -> Date {
        let step = 60.0
        let interval = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: ceil(interval / step) * step)
    }

    /// Floors a date down to the granularity boundary.
    static func floored(_ date: Date, toMinutes minutes: Int = startGranularityMinutes) -> Date {
        let step = Double(minutes * 60)
        let interval = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: floor(interval / step) * step)
    }
}
