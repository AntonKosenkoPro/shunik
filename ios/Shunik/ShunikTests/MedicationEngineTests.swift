import Foundation
import Testing
@testable import Shunik

/// Pure scheduling rules (§6.3): slot windows, the ISO→Calendar weekday
/// mapping, PRN emptiness, auto-miss, adherence, and future-pending pruning.
/// All dates go through `Calendar.current` on both sides, so the suite is
/// timezone-independent.
@Suite("Medication engine")
struct MedicationEngineTests {
    private func makeCourse(
        scheduleKind: String = "daily",
        times: String = "08:00",
        weekdays: String = "",
        durationDays: Int = 0,
        endsOn: String? = nil,
        status: String = "active"
    ) -> MedCourseRecord {
        MedCourseRecord(
            drugName: "Amox", doseAmount: "0.5", doseUnit: "tab", route: "oral",
            scheduleKind: scheduleKind, scheduleTimes: times, scheduleWeekdays: weekdays,
            durationDays: durationDays, endsOn: endsOn, status: status,
            instructions: "", infoRef: ""
        )
    }

    private func localDate(_ date: Date, hour: Int, minute: Int = 0) throws -> Date {
        let calendar = Calendar.current
        return try #require(calendar.date(
            bySettingHour: hour, minute: minute, second: 0,
            of: calendar.startOfDay(for: date)
        ))
    }

    private func monday() throws -> Date {
        let ref = try #require(RFC3339Milli.parse("2026-10-19T12:00:00.000Z"))
        return try #require(Calendar.current.nextDate(
            after: ref,
            matching: DateComponents(weekday: 2),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ))
    }

    // MARK: - Parsing

    @Test("times parse, sort, dedupe, and drop garbage")
    func timesParsing() {
        #expect(MedicationEngine.parseTimes("20:00, 08:00,08:00,xx,25:00,8:61").map { "\($0.hour):\($0.minute)" } == ["8:0", "20:0"])
        #expect(MedicationEngine.parseTimes("").isEmpty)
        #expect(MedicationEngine.parseTimes("nope").isEmpty)
    }

    @Test("weekdays parse Mon=1..Sun=7, sorted and deduped")
    func weekdaysParsing() {
        #expect(MedicationEngine.parseWeekdays("7,1,3,1,0,8,x") == [1, 3, 7])
    }

    @Test("ISO weekday maps to Calendar weekday (Sun 7 wraps to 1)")
    func weekdayMapping() {
        #expect(MedicationEngine.calendarWeekday(isoWeekday: 1) == 2)
        #expect(MedicationEngine.calendarWeekday(isoWeekday: 3) == 4)
        #expect(MedicationEngine.calendarWeekday(isoWeekday: 6) == 7)
        #expect(MedicationEngine.calendarWeekday(isoWeekday: 7) == 1)
    }

    // MARK: - Slots

    @Test("daily slots span start day through now + horizon")
    func dailySlots() throws {
        let createdAt = try #require(RFC3339Milli.parse("2026-10-20T10:00:00.000Z"))
        let now = try #require(RFC3339Milli.parse("2026-10-22T12:00:00.000Z"))
        let course = makeCourse(times: "08:00,20:00")
        let slots = MedicationEngine.dueSlots(course: course, courseCreatedAt: createdAt, now: now, horizonDays: 14)
        // Oct 20 .. Nov 4 full days (x2) + Nov 5 08:00 only (20:00 is past
        // now + 14 days = Nov 5 12:00Z): 16 * 2 + 1.
        #expect(slots.count == 33)
        #expect(slots == slots.sorted())
        #expect(slots.first == (try localDate(createdAt, hour: 8)))
    }

    @Test("durationDays caps the window (inclusive last day)")
    func durationCapsWindow() throws {
        let createdAt = try #require(RFC3339Milli.parse("2026-10-20T10:00:00.000Z"))
        let now = try #require(RFC3339Milli.parse("2026-10-22T12:00:00.000Z"))
        let course = makeCourse(times: "08:00", durationDays: 2)
        let slots = MedicationEngine.dueSlots(course: course, courseCreatedAt: createdAt, now: now)
        #expect(slots.count == 2)
    }

    @Test("endsOn caps the window (inclusive); earliest cap wins")
    func endsOnCapsWindow() throws {
        let createdAt = try #require(RFC3339Milli.parse("2026-10-20T10:00:00.000Z"))
        let now = try #require(RFC3339Milli.parse("2026-10-22T12:00:00.000Z"))
        let capped = makeCourse(times: "08:00", durationDays: 10, endsOn: "2026-10-21")
        #expect(MedicationEngine.dueSlots(course: capped, courseCreatedAt: createdAt, now: now).count == 2)
        let uncapped = makeCourse(times: "08:00", endsOn: "not-a-date")
        #expect(!MedicationEngine.dueSlots(course: uncapped, courseCreatedAt: createdAt, now: now).isEmpty)
    }

    @Test("weekday courses fire only on mapped days")
    func weekdaySlots() throws {
        let mondayMorning = try monday()
        let calendar = Calendar.current
        let createdAt = try #require(calendar.date(
            bySettingHour: 10, minute: 0, second: 0, of: mondayMorning
        ))
        let now = calendar.date(byAdding: .hour, value: 1, to: createdAt) ?? createdAt
        let course = makeCourse(scheduleKind: "weekdays", times: "09:00", weekdays: "1")
        let slots = MedicationEngine.dueSlots(course: course, courseCreatedAt: createdAt, now: now, horizonDays: 7)
        // This Monday 09:00 plus next Monday 09:00 (<= now + 7 days).
        #expect(slots.count == 2)
        for slot in slots {
            #expect(calendar.component(.weekday, from: slot) == 2)
        }
        let tuesdayOnly = makeCourse(scheduleKind: "weekdays", times: "09:00", weekdays: "2")
        let tuesdaySlots = MedicationEngine.dueSlots(
            course: tuesdayOnly, courseCreatedAt: createdAt, now: now, horizonDays: 1
        )
        #expect(tuesdaySlots.count == 1)
    }

    @Test("prn, non-active, and time-less courses yield no slots")
    func emptySlots() throws {
        let createdAt = try #require(RFC3339Milli.parse("2026-10-20T10:00:00.000Z"))
        let now = try #require(RFC3339Milli.parse("2026-10-22T12:00:00.000Z"))
        #expect(MedicationEngine.dueSlots(
            course: makeCourse(scheduleKind: "prn"), courseCreatedAt: createdAt, now: now
        ).isEmpty)
        #expect(MedicationEngine.dueSlots(
            course: makeCourse(status: "paused"), courseCreatedAt: createdAt, now: now
        ).isEmpty)
        #expect(MedicationEngine.dueSlots(
            course: makeCourse(times: "bogus"), courseCreatedAt: createdAt, now: now
        ).isEmpty)
        #expect(MedicationEngine.dueSlots(
            course: makeCourse(scheduleKind: "weekdays", times: "08:00", weekdays: ""),
            courseCreatedAt: createdAt, now: now
        ).isEmpty)
    }

    // MARK: - Materialize

    @Test("materialize skips covered slots and snapshots the dose")
    func materialize() throws {
        let createdAt = try #require(RFC3339Milli.parse("2026-10-20T10:00:00.000Z"))
        let now = try #require(RFC3339Milli.parse("2026-10-20T12:00:00.000Z"))
        let course = makeCourse(times: "08:00,20:00")
        let first = RFC3339Milli.format(try localDate(createdAt, hour: 8))
        let rows = MedicationEngine.materialize(
            courseID: "c1", householdID: "hh-1", course: course,
            courseCreatedAt: createdAt, now: now, existingDueAts: [first]
        )
        #expect(!rows.isEmpty)
        #expect(!rows.map(\.dueAt).contains(first))
        for row in rows {
            #expect(row.id.isEmpty)
            #expect(row.status == "pending")
            #expect(row.takenAt == nil)
            #expect(row.doseSnapshot == "0.5 tab")
        }
    }

    // MARK: - Transitions

    private func intake(
        id: String,
        dueAt: String?,
        status: String,
        courseID: String = "c1"
    ) -> IntakeRecord {
        IntakeRecord(
            id: id, householdID: "hh-1", courseID: courseID, dueAt: dueAt,
            status: status, takenAt: nil, doseSnapshot: "0.5 tab", note: "",
            markedBy: "u1", createdAt: "2026-10-20T10:00:00.000Z",
            updatedAt: "2026-10-20T10:00:00.000Z"
        )
    }

    @Test("auto-miss flips a pending only when a later intake is due")
    func autoMiss() throws {
        let now = try #require(RFC3339Milli.parse("2026-10-22T12:00:00.000Z"))
        let rows = [
            intake(id: "a", dueAt: "2026-10-20T08:00:00.000Z", status: "pending"),
            intake(id: "b", dueAt: "2026-10-21T08:00:00.000Z", status: "pending"),
            intake(id: "c", dueAt: "2026-10-23T08:00:00.000Z", status: "pending"),
            intake(id: "d", dueAt: "2026-10-20T08:00:00.000Z", status: "taken"),
            intake(id: "e", dueAt: nil, status: "pending")
        ]
        let flipped = MedicationEngine.autoMiss(intakes: rows, now: now)
        let byID = Dictionary(uniqueKeysWithValues: flipped.map { ($0.id, $0.status) })
        #expect(byID["a"] == "missed")
        #expect(byID["b"] == "pending")
        #expect(byID["c"] == "pending")
        #expect(byID["d"] == "taken")
        #expect(byID["e"] == "pending")
    }

    @Test("equal dueAts never miss each other; other courses are ignored")
    func autoMissEqualDueAts() throws {
        let now = try #require(RFC3339Milli.parse("2026-10-22T12:00:00.000Z"))
        let rows = [
            intake(id: "a", dueAt: "2026-10-20T08:00:00.000Z", status: "pending"),
            intake(id: "b", dueAt: "2026-10-20T08:00:00.000Z", status: "pending"),
            intake(id: "c", dueAt: "2026-10-20T08:00:00.000Z", status: "pending", courseID: "c2")
        ]
        let flipped = MedicationEngine.autoMiss(intakes: rows, now: now)
        #expect(flipped.allSatisfy { $0.status == "pending" })
    }

    @Test("adherence excludes skipped; prn logs give a zero denominator")
    func adherence() {
        let scheduled = [
            intake(id: "a", dueAt: "2026-10-20T08:00:00.000Z", status: "taken"),
            intake(id: "b", dueAt: "2026-10-21T08:00:00.000Z", status: "missed"),
            intake(id: "c", dueAt: "2026-10-22T08:00:00.000Z", status: "skipped"),
            intake(id: "d", dueAt: "2026-10-23T08:00:00.000Z", status: "pending")
        ]
        #expect(MedicationEngine.adherence(intakes: scheduled) == (1, 3))
        let prn = [
            intake(id: "p1", dueAt: nil, status: "taken"),
            intake(id: "p2", dueAt: nil, status: "taken")
        ]
        #expect(MedicationEngine.adherence(intakes: prn) == (2, 0))
        #expect(MedicationEngine.adherence(intakes: []) == (0, 0))
    }

    @Test("futurePendings keeps only pending present/future rows")
    func futurePendings() throws {
        let now = try #require(RFC3339Milli.parse("2026-10-22T12:00:00.000Z"))
        let rows = [
            intake(id: "past", dueAt: "2026-10-20T08:00:00.000Z", status: "pending"),
            intake(id: "future", dueAt: "2026-10-23T08:00:00.000Z", status: "pending"),
            intake(id: "undated", dueAt: nil, status: "pending"),
            intake(id: "settled", dueAt: "2026-10-23T08:00:00.000Z", status: "taken")
        ]
        let pruned = MedicationEngine.futurePendings(intakes: rows, now: now)
        #expect(Set(pruned.map(\.id)) == ["future", "undated"])
    }
}
