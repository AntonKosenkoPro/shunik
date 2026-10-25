import Foundation
import Testing
@testable import Shunik

/// `MedicationsViewModel` against a real `LocalStore` (§6.3): load
/// materializes pendings, mark persists, stop prunes only futures, and PRN
/// courses log taken intakes without ever materializing pendings.
@Suite("Medications view model")
@MainActor
struct MedicationsViewModelTests {
    private func tempStore() throws -> LocalStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try LocalStore(url: dir.appendingPathComponent("test.db"))
    }

    private func makePet(in store: LocalStore) async throws -> PetRecord {
        try await store.createPet(
            PetRecord(
                id: "pet-1", householdID: "hh-1", name: "Shunik", species: "cat",
                birthdate: nil, notes: "",
                createdAt: "2026-10-20T10:00:00.000Z",
                updatedAt: "2026-10-20T10:00:00.000Z", updatedBy: "u1"
            ),
            updatedBy: "u1"
        )
    }

    private func makeCourseEvent(
        scheduleKind: String = "daily",
        times: String = "08:00",
        status: String = "active"
    ) throws -> EventRecord {
        let json = "{\"id\":\"\",\"household_id\":\"hh-1\",\"pet_id\":\"pet-1\"," +
            "\"kind\":\"med_course\",\"occurred_at\":\"2026-10-26T12:00:00.000Z\"," +
            "\"title\":\"Amox\"," +
            "\"detail\":{\"course\":{\"drug_name\":\"Amox\",\"dose_amount\":\"0.5\"," +
            "\"dose_unit\":\"tab\",\"route\":\"oral\",\"schedule_kind\":\"\(scheduleKind)\"," +
            "\"schedule_times\":\"\(times)\",\"schedule_weekdays\":\"\"," +
            "\"duration_days\":0,\"status\":\"\(status)\"," +
            "\"instructions\":\"\",\"info_ref\":\"\"}}," +
            "\"created_at\":\"2026-10-26T11:00:00.000Z\"," +
            "\"updated_at\":\"2026-10-26T11:00:00.000Z\",\"updated_by\":\"u1\"}"
        return try JSONDecoder().decode(EventRecord.self, from: Data(json.utf8))
    }

    private func makeViewModel(store: LocalStore) -> MedicationsViewModel {
        MedicationsViewModel(
            store: store,
            undo: UndoBufferStore(store: store),
            sync: SyncController(store: store, connectivity: Connectivity()),
            sessionUserID: "u1"
        )
    }

    private func seedCourse(
        store: LocalStore,
        scheduleKind: String = "daily",
        times: String = "08:00",
        status: String = "active"
    ) async throws -> EventRecord {
        _ = try await makePet(in: store)
        return try await store.createEvent(
            makeCourseEvent(scheduleKind: scheduleKind, times: times, status: status),
            updatedBy: "u1"
        )
    }

    @Test("load materializes pendings for an active scheduled course")
    func loadMaterializesPendings() async throws {
        let store = try tempStore()
        let course = try await seedCourse(store: store)
        let viewModel = makeViewModel(store: store)
        await viewModel.load()
        #expect(viewModel.courses.count == 1)
        #expect(viewModel.courses.first?.id == course.id)
        let intakes = try await store.listIntakes(courseID: course.id)
        #expect(!intakes.isEmpty)
        #expect(intakes.allSatisfy { $0.status == "pending" })
        #expect(!viewModel.dueIntakes.isEmpty)
        let adherence = viewModel.adherence(courseID: course.id)
        #expect(adherence.taken == 0)
        #expect(adherence.denominator == intakes.count)
    }

    @Test("mark taken persists status and takenAt")
    func markTakenPersists() async throws {
        let store = try tempStore()
        let course = try await seedCourse(store: store)
        let viewModel = makeViewModel(store: store)
        await viewModel.load()
        let pending = try #require(viewModel.intakes(courseID: course.id).first)
        await viewModel.mark(pending, status: "taken")
        let stored = try #require(await store.getIntake(id: pending.id))
        #expect(stored.status == "taken")
        #expect(stored.takenAt != nil)
        #expect(viewModel.adherence(courseID: course.id).taken == 1)
    }

    @Test("stop prunes future pendings and keeps settled history")
    func stopPrunesFuturesOnly() async throws {
        let store = try tempStore()
        let course = try await seedCourse(store: store)
        let viewModel = makeViewModel(store: store)
        await viewModel.load()
        let pastTaken = IntakeRecord(
            id: "", householdID: "hh-1", courseID: course.id,
            dueAt: "2020-01-01T08:00:00.000Z", status: "taken",
            takenAt: "2020-01-01T08:05:00.000Z", doseSnapshot: "0.5 tab",
            note: "", markedBy: "", createdAt: "", updatedAt: ""
        )
        let kept = try await store.createIntake(pastTaken, markedBy: "u1")
        let futurePending = IntakeRecord(
            id: "", householdID: "hh-1", courseID: course.id,
            dueAt: "2099-01-01T08:00:00.000Z", status: "pending",
            takenAt: nil, doseSnapshot: "0.5 tab",
            note: "", markedBy: "", createdAt: "", updatedAt: ""
        )
        let pruned = try await store.createIntake(futurePending, markedBy: "u1")
        await viewModel.stopCourse(course)
        let stopped = try #require(await store.getEvent(id: course.id))
        #expect(stopped.course?.status == "stopped")
        #expect(try await store.getIntake(id: pruned.id) == nil)
        #expect(try await store.getIntake(id: kept.id) != nil)
        let remaining = try await store.listIntakes(courseID: course.id)
        #expect(remaining.allSatisfy { $0.status != "pending" || ($0.dueAt ?? "") <= RFC3339Milli.nowString() })
    }

    @Test("PRN courses log taken intakes and never materialize pendings")
    func prnLogCreatesTakenIntake() async throws {
        let store = try tempStore()
        let course = try await seedCourse(store: store, scheduleKind: "prn", times: "")
        let viewModel = makeViewModel(store: store)
        await viewModel.load()
        #expect((try await store.listIntakes(courseID: course.id)).isEmpty)
        await viewModel.logPrn(course: course)
        let intakes = try await store.listIntakes(courseID: course.id)
        #expect(intakes.count == 1)
        #expect(intakes.first?.status == "taken")
        #expect(intakes.first?.dueAt == nil)
        #expect(intakes.first?.takenAt != nil)
        #expect(viewModel.dueIntakes.isEmpty)
    }
}
