import Testing
import Foundation
@testable import Shunik

/// Reminder engine: derived queue, deterministic ids, reschedule handling,
/// mute, and one-time permission ask — all against a fake center.
@MainActor
@Suite("ReminderEngine")
struct ReminderEngineTests {

    private final class FakeCenter: ReminderCenter, @unchecked Sendable {
        var status: ReminderAuthStatus = .notDetermined
        var granted = true
        var scheduled: [String: (title: String, body: String, dueAt: Date)] = [:]
        var cancelled: [String] = []

        func authorization() async -> ReminderAuthStatus { status }
        func requestAuthorization() async -> Bool {
            status = granted ? .granted : .denied
            return granted
        }

        func pendingIDs() async -> Set<String> { Set(scheduled.keys) }

        func schedule(id: String, title: String, body: String, dueAt: Date) async throws {
            scheduled[id] = (title, body, dueAt)
        }

        func cancel(ids: [String]) async {
            cancelled.append(contentsOf: ids)
            for id in ids { scheduled.removeValue(forKey: id) }
        }
    }

    private func tempStore() throws -> LocalStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("reminders.db")
        return try LocalStore(url: url, householdID: "hh-rem")
    }

    private func makeEngine(store: LocalStore, center: FakeCenter? = nil) -> (ReminderEngine, FakeCenter) {
        let fake = center ?? FakeCenter()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let engine = ReminderEngine(store: store, center: fake, defaults: defaults)
        return (engine, fake)
    }

    private func vaccJSON(id: String, petID: String, nextDue: String?) -> String {
        let due = nextDue.map { "\"next_due_at\":\"\($0)\"," } ?? ""
        return "{\"id\":\"\(id)\",\"household_id\":\"hh-rem\",\"pet_id\":\"\(petID)\"," +
            "\"kind\":\"vaccination\",\"occurred_at\":\"2026-10-20T12:00:00.000Z\"," +
            "\"title\":\"Rabies\"," + due +
            "\"detail\":{\"vaccination\":{\"vaccine\":\"Rabivak\",\"batch\":\"\",\"vet\":\"\",\"notes\":\"\"}}," +
            "\"created_at\":\"2026-10-20T11:00:00.000Z\",\"updated_at\":\"2026-10-26T12:00:00.000Z\",\"updated_by\":\"u1\"}"
    }

    @Test("queue derives event dues and pending intakes with deterministic ids")
    func derivesQueue() async throws {
        let store = try tempStore()
        let pet = try await store.createPet(
            PetRecord(id: "pet-1", householdID: "hh-rem", name: "Bars", species: "cat",
                      birthdate: nil, notes: "", createdAt: "2026-10-20T11:00:00.000Z",
                      updatedAt: "2026-10-20T11:00:00.000Z", updatedBy: "u1"),
            updatedBy: "u1"
        )
        let event = try JSONDecoder().decode(EventRecord.self, from: Data(vaccJSON(id: "ev-1", petID: pet.id, nextDue: "2026-10-28T09:00:00.000Z").utf8))
        _ = try await store.createEvent(event, updatedBy: "u1")
        let now = try #require(RFC3339Milli.parse("2026-10-26T12:00:00.000Z"))
        let (engine, _) = makeEngine(store: store)

        let items = try await engine.desiredItems(now: now)

        #expect(items.map(\.id) == ["due_ev-1"])
        #expect(items[0].title == "Rabies")
    }

    @Test("window drops far-future dues but keeps overdue ones")
    func rollingWindow() async throws {
        let store = try tempStore()
        let pet = try await store.createPet(
            PetRecord(id: "pet-1", householdID: "hh-rem", name: "Bars", species: "cat",
                      birthdate: nil, notes: "", createdAt: "2026-10-20T11:00:00.000Z",
                      updatedAt: "2026-10-20T11:00:00.000Z", updatedBy: "u1"),
            updatedBy: "u1"
        )
        let far = try JSONDecoder().decode(EventRecord.self, from: Data(vaccJSON(id: "ev-far", petID: pet.id, nextDue: "2027-06-01T09:00:00.000Z").utf8))
        _ = try await store.createEvent(far, updatedBy: "u1")
        let past = try JSONDecoder().decode(EventRecord.self, from: Data(vaccJSON(id: "ev-past", petID: pet.id, nextDue: "2026-10-20T09:00:00.000Z").utf8))
        _ = try await store.createEvent(past, updatedBy: "u1")
        let now = try #require(RFC3339Milli.parse("2026-10-26T12:00:00.000Z"))
        let (engine, _) = makeEngine(store: store)

        let ids = try await engine.desiredItems(now: now).map(\.id)

        #expect(!ids.contains("due_ev-far"))
        #expect(ids.contains("due_ev-past"))
    }

    @Test("refresh schedules new dues and cancels resolved ones")
    func refreshReconciles() async throws {
        let store = try tempStore()
        let pet = try await store.createPet(
            PetRecord(id: "pet-1", householdID: "hh-rem", name: "Bars", species: "cat",
                      birthdate: nil, notes: "", createdAt: "2026-10-20T11:00:00.000Z",
                      updatedAt: "2026-10-20T11:00:00.000Z", updatedBy: "u1"),
            updatedBy: "u1"
        )
        let event = try JSONDecoder().decode(EventRecord.self, from: Data(vaccJSON(id: "ev-1", petID: pet.id, nextDue: "2026-10-28T09:00:00.000Z").utf8))
        _ = try await store.createEvent(event, updatedBy: "u1")
        let (engine, fake) = makeEngine(store: store)

        await engine.refresh()
        #expect(fake.scheduled["due_ev-1"] != nil)

        // Event deleted → next refresh cancels the pending request.
        try await store.deleteEvent(id: "ev-1", updatedBy: "u1")
        fake.scheduled.removeAll()
        fake.scheduled["due_ev-1"] = ("stale", "stale", Date())
        await engine.refresh()
        #expect(fake.cancelled.contains("due_ev-1"))
        #expect(fake.scheduled["due_ev-1"] == nil)
    }

    @Test("rescheduled due cancels the old fire date and adds the new one")
    func rescheduleReplaces() async throws {
        let store = try tempStore()
        let pet = try await store.createPet(
            PetRecord(id: "pet-1", householdID: "hh-rem", name: "Bars", species: "cat",
                      birthdate: nil, notes: "", createdAt: "2026-10-20T11:00:00.000Z",
                      updatedAt: "2026-10-20T11:00:00.000Z", updatedBy: "u1"),
            updatedBy: "u1"
        )
        var event = try JSONDecoder().decode(EventRecord.self, from: Data(vaccJSON(id: "ev-1", petID: pet.id, nextDue: "2026-10-28T09:00:00.000Z").utf8))
        let created = try await store.createEvent(event, updatedBy: "u1")
        let (engine, fake) = makeEngine(store: store)
        await engine.refresh()
        #expect(fake.scheduled["due_ev-1"] != nil)

        event.nextDueAt = "2026-10-30T09:00:00.000Z"
        _ = try await store.updateEvent(event, baseUpdatedAt: created.updatedAt, updatedBy: "u1")
        await engine.refresh()

        #expect(fake.cancelled.contains("due_ev-1"))
        let fire = try #require(fake.scheduled["due_ev-1"]?.dueAt)
        #expect(RFC3339Milli.format(fire) == "2026-10-30T09:00:00.000Z")
    }

    @Test("muted device schedules nothing and clears pending")
    func muteSilences() async throws {
        let store = try tempStore()
        let pet = try await store.createPet(
            PetRecord(id: "pet-1", householdID: "hh-rem", name: "Bars", species: "cat",
                      birthdate: nil, notes: "", createdAt: "2026-10-20T11:00:00.000Z",
                      updatedAt: "2026-10-20T11:00:00.000Z", updatedBy: "u1"),
            updatedBy: "u1"
        )
        let event = try JSONDecoder().decode(EventRecord.self, from: Data(vaccJSON(id: "ev-1", petID: pet.id, nextDue: "2026-10-28T09:00:00.000Z").utf8))
        _ = try await store.createEvent(event, updatedBy: "u1")
        let (engine, fake) = makeEngine(store: store)
        fake.scheduled["due_ev-1"] = ("old", "old", Date())

        await engine.setMuted(true)
        #expect(fake.scheduled.isEmpty)

        // Still muted: refresh schedules nothing.
        await engine.refresh()
        #expect(fake.scheduled.isEmpty)

        // Unmuted: top-up restores the due.
        await engine.setMuted(false)
        await engine.refresh()
        #expect(fake.scheduled["due_ev-1"] != nil)
    }

    @Test("permission is requested once; denial stays graceful")
    func permissionOnce() async throws {
        let store = try tempStore()
        let (engine, fake) = makeEngine(store: store)

        await engine.noteDueCreated()
        #expect(fake.status == .granted)

        // Second due: no second prompt (asked flag set).
        fake.status = .notDetermined
        await engine.noteDueCreated()
        #expect(fake.status == .notDetermined)

        // Denied center: ensurePermission returns false without throwing.
        fake.status = .denied
        #expect(await engine.ensurePermission() == false)
    }

    @Test("single-pet bodies carry no pet prefix; multi-pet bodies do")
    func petPrefixRule() {
        #expect(ReminderEngine.prefixed(pet: "Bars", multiPet: false, detail: "Rabivak") == "Rabivak")
        #expect(ReminderEngine.prefixed(pet: "Bars", multiPet: true, detail: "Rabivak") == "Bars • Rabivak")
        #expect(ReminderEngine.prefixed(pet: nil, multiPet: true, detail: "Rabivak") == "Rabivak")
    }
}
