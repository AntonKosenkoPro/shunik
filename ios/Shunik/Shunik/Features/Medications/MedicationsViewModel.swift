import Combine
import Foundation

/// Builds a new `med_course` event. `EventRecord` has no memberwise init
/// (custom `init(from:)`), so construction goes through the same JSON shape
/// the store decodes — `id` stays empty for the store's id generator, and
/// `householdID` must be the target pet's (create stamps nothing).
private func makeMedicationCourseEvent(
    petID: String,
    householdID: String,
    detail: MedCourseRecord,
    userID: String,
    now: Date = Date()
) throws -> EventRecord {
    let nowString = RFC3339Milli.format(now)
    let courseJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(detail))
    let dict: [String: Any] = [
        "id": "", "household_id": householdID, "pet_id": petID,
        "kind": MedicationEngine.courseKind, "occurred_at": nowString,
        "title": detail.drugName, "course": courseJSON,
        "created_at": nowString, "updated_at": nowString, "updated_by": userID
    ]
    let data = try JSONSerialization.data(withJSONObject: dict)
    return try JSONDecoder().decode(EventRecord.self, from: data)
}

/// Localized one-line schedule summary (views share it; data values like
/// times stay verbatim — only the kind word is localized).
func medicationScheduleSummary(_ course: MedCourseRecord) -> String {
    let kind: String
    switch course.scheduleKind {
    case "daily": kind = L10n.medsScheduleDaily.text
    case "weekdays": kind = L10n.medsScheduleWeekdays.text
    default: kind = L10n.medsSchedulePrn.text
    }
    let times = course.scheduleTimes.trimmingCharacters(in: .whitespaces)
    if course.scheduleKind == "prn" || times.isEmpty { return kind }
    return "\(kind) · \(times)"
}

/// Medications (§6.3): courses are `med_course` events; givings are intake
/// rows. The VM owns the scheduling side effects: `load()` auto-misses past
/// pendings (persisted via `updateIntake` with the fetched base) and
/// materializes missing slots (persisted via `createIntake`), then rebuilds
/// the due feed. Past (settled) intakes are never rewritten.
@MainActor
final class MedicationsViewModel: ObservableObject {
    @Published private(set) var courses: [EventRecord] = []
    @Published private(set) var dueIntakes: [(intake: IntakeRecord, course: EventRecord, petName: String)] = []
    @Published private(set) var pets: [PetRecord] = []
    @Published var selectedPetID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var operationError: String?

    private let store: LocalStore
    private let undo: UndoBufferStore
    private let sync: SyncController
    private let sessionUserID: String
    private var intakesByCourse: [String: [IntakeRecord]] = [:]
    /// Title snapshots of deleted courses: their settled intakes stay in the
    /// store (history never mutates) but the event row is gone, so the detail
    /// view falls back to these for its header.
    private var deletedCourseSnapshots: [String: EventRecord] = [:]

    init(store: LocalStore, undo: UndoBufferStore, sync: SyncController, sessionUserID: String) {
        self.store = store
        self.undo = undo
        self.sync = sync
        self.sessionUserID = sessionUserID
    }

    // MARK: - Scope

    var requiresChrome: Bool {
        PetScope.requiresChrome(petCount: pets.count)
    }

    var effectivePetID: String? {
        PetScope.effectiveSelection(petCount: pets.count, selectedID: selectedPetID)
    }

    func petName(for petID: String) -> String {
        pets.first { $0.id == petID }?.name ?? ""
    }

    func courseEvent(id: String) -> EventRecord? {
        courses.first { $0.id == id } ?? deletedCourseSnapshots[id]
    }

    func intakes(courseID: String) -> [IntakeRecord] {
        (intakesByCourse[courseID] ?? []).sorted {
            ($0.dueAt ?? "") > ($1.dueAt ?? "")
        }
    }

    func adherence(courseID: String) -> (taken: Int, denominator: Int) {
        MedicationEngine.adherence(intakes: intakesByCourse[courseID] ?? [])
    }

    // MARK: - Load

    /// Reloads pets + courses, applies auto-miss transitions, materializes
    /// missing slots, and rebuilds the due feed. Idempotent: covered slots
    /// are skipped, settled rows untouched.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            pets = try await store.listPets()
            let ids = pets.map(\.id)
            if ids.count == 1 {
                selectedPetID = ids[0]
            } else if let selected = selectedPetID, !ids.contains(selected) {
                selectedPetID = nil
            }
            courses = try await loadAllCourses()
            let now = Date()
            for course in courses {
                guard let detail = course.course, detail.status == "active" else { continue }
                let existing = try await store.listIntakes(courseID: course.id)
                let createdAt = RFC3339Milli.parse(course.createdAt) ?? now
                for row in MedicationEngine.autoMiss(intakes: existing, now: now) {
                    let prior = existing.first { $0.id == row.id }
                    guard row.status != prior?.status, let current = prior else { continue }
                    _ = try await store.updateIntake(row, baseUpdatedAt: current.updatedAt, markedBy: sessionUserID)
                }
                let settled = try await store.listIntakes(courseID: course.id)
                let covered = Set(settled.compactMap(\.dueAt))
                let fresh = MedicationEngine.materialize(
                    courseID: course.id, householdID: course.householdID, course: detail,
                    courseCreatedAt: createdAt, now: now, existingDueAts: covered
                )
                for row in fresh {
                    _ = try await store.createIntake(row, markedBy: sessionUserID)
                }
            }
            var cache: [String: [IntakeRecord]] = [:]
            for course in courses {
                cache[course.id] = try await store.listIntakes(courseID: course.id)
                if deletedCourseSnapshots[course.id] != nil {
                    deletedCourseSnapshots.removeValue(forKey: course.id)
                }
            }
            intakesByCourse = cache
            rebuildDue(now: now)
            operationError = nil
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func loadAllCourses() async throws -> [EventRecord] {
        let all = try await store.listAllEvents()
        let scoped: [EventRecord]
        if let scope = effectivePetID {
            scoped = all.filter { $0.petID == scope }
        } else {
            scoped = all
        }
        return scoped.filter { $0.kind == MedicationEngine.courseKind }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    private func rebuildDue(now: Date) {
        let calendar = Calendar.current
        let endOfToday = calendar.date(
            bySettingHour: 23, minute: 59, second: 59, of: now
        ).map(RFC3339Milli.format) ?? RFC3339Milli.format(now)
        var due: [(intake: IntakeRecord, course: EventRecord, petName: String)] = []
        for course in courses {
            for intake in intakesByCourse[course.id] ?? [] {
                guard intake.status == "pending",
                      let dueAt = intake.dueAt,
                      dueAt <= endOfToday
                else { continue }
                due.append((intake, course, petName(for: course.petID)))
            }
        }
        dueIntakes = due.sorted { $0.intake.dueAt ?? "" < $1.intake.dueAt ?? "" }
    }

    // MARK: - Mutations

    /// Marks one intake taken/missed/skipped. `taken` stamps `takenAt = now`;
    /// other statuses clear it. Ends with `load()` (re-materialize + rebuild).
    func mark(_ intake: IntakeRecord, status: String) async {
        do {
            guard var current = try await store.getIntake(id: intake.id) else { return }
            current.status = status
            current.takenAt = status == "taken" ? RFC3339Milli.nowString() : nil
            _ = try await store.updateIntake(current, baseUpdatedAt: intake.updatedAt, markedBy: sessionUserID)
            sync.trigger(userID: sessionUserID)
            await load()
        } catch {
            operationError = error.localizedDescription
            await load()
        }
    }

    /// Logs one PRN giving: a `"taken"` intake with no `dueAt` (PRN courses
    /// never materialize pendings, so there is nothing to mark — every
    /// giving is a fresh log with `takenAt = now`).
    func logPrn(course: EventRecord) async {
        do {
            guard let detail = course.course else { return }
            let dose = "\(detail.doseAmount) \(detail.doseUnit)".trimmingCharacters(in: .whitespaces)
            let row = IntakeRecord(
                id: "", householdID: course.householdID, courseID: course.id, dueAt: nil,
                status: "taken", takenAt: RFC3339Milli.nowString(), doseSnapshot: dose,
                note: "", markedBy: "", createdAt: "", updatedAt: ""
            )
            _ = try await store.createIntake(row, markedBy: sessionUserID)
            sync.trigger(userID: sessionUserID)
            await load()
        } catch {
            operationError = error.localizedDescription
        }
    }

    /// Early stop: flips the course to `"stopped"` and tombstones its future
    /// pendings via `deleteIntake` (synced deletes, per §4). Settled history
    /// stays. The view confirms with `meds.stopTitle` / `meds.stopMessage`.
    func stopCourse(_ course: EventRecord) async {
        do {
            guard var current = try await store.getEvent(id: course.id),
                  var detail = current.course
            else { return }
            detail.status = "stopped"
            current.course = detail
            _ = try await store.updateEvent(current, baseUpdatedAt: current.updatedAt, updatedBy: sessionUserID)
            let intakes = try await store.listIntakes(courseID: course.id)
            for row in MedicationEngine.futurePendings(intakes: intakes, now: Date()) {
                try await store.deleteIntake(id: row.id, markedBy: sessionUserID)
            }
            sync.trigger(userID: sessionUserID)
            await load()
        } catch {
            operationError = error.localizedDescription
            await load()
        }
    }

    /// Undo-buffered delete (two-step: buffer first, then `removeEventLocal`).
    /// Future pendings are tombstoned via `deleteIntake` (synced); settled
    /// intakes stay as history under the now-orphaned `courseID` — the detail
    /// view falls back to the snapshot kept here for its header. Undo
    /// restores the course row, not the pruned pendings (documented tradeoff).
    func deleteCourse(_ course: EventRecord) async {
        do {
            deletedCourseSnapshots[course.id] = course
            try await undo.bufferDeletion(of: [(resource: .event, id: course.id)])
            let intakes = try await store.listIntakes(courseID: course.id)
            for row in MedicationEngine.futurePendings(intakes: intakes, now: Date()) {
                try await store.deleteIntake(id: row.id, markedBy: sessionUserID)
            }
            try await store.removeEventLocal(id: course.id)
            sync.trigger(userID: sessionUserID)
            await load()
        } catch {
            operationError = error.localizedDescription
            await load()
        }
    }

    /// Creates (new `med_course` event, `occurredAt = now`) or updates
    /// (full-replace with the fresh base) a course. The form owns field
    /// validation; the drug name becomes the event title.
    func saveCourse(courseID: String?, petID: String, detail: MedCourseRecord) async {
        do {
            if let courseID, var current = try await store.getEvent(id: courseID) {
                current.course = detail
                current.title = detail.drugName
                _ = try await store.updateEvent(current, baseUpdatedAt: current.updatedAt, updatedBy: sessionUserID)
            } else {
                var householdID = pets.first?.householdID ?? ""
                if let found = try? await store.getPet(id: petID) {
                    householdID = found.householdID
                }
                let event = try makeMedicationCourseEvent(
                    petID: petID, householdID: householdID, detail: detail, userID: sessionUserID
                )
                _ = try await store.createEvent(event, updatedBy: sessionUserID)
            }
            sync.trigger(userID: sessionUserID)
            await load()
        } catch {
            operationError = error.localizedDescription
        }
    }
}
