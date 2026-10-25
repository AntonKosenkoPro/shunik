import Foundation

/// Pure medication scheduling logic (§6.3). No store dependency: every input
/// is a plain value, so the whole surface is unit-testable without a database.
///
/// Conventions (mirror the backend contract + `SyncModels`):
/// - Course rows are events of kind `"med_course"`; `courseCreatedAt` is the
///   event's `createdAt` (schedule window opens on that calendar day).
/// - `scheduleKind` is `"daily"`, `"weekdays"`, or `"prn"`.
/// - `scheduleTimes` is `"HH:MM,HH:MM"` (24h, wall-clock local).
/// - `scheduleWeekdays` lists ISO days `Mon=1..Sun=7`, comma-separated.
/// - Slot timestamps are RFC3339-millisecond UTC strings (`RFC3339Milli`):
///   fixed-width, so plain string comparison IS chronological order.
/// - Statuses: course `"active"` (only scheduled kind when active produces
///   slots); intake `"pending"` / `"taken"` / `"missed"` / `"skipped"`.
enum MedicationEngine {
    /// The event kind carrying a `MedCourseRecord` detail.
    static let courseKind = "med_course"

    // MARK: - Parsing

    /// Parses `"HH:MM,HH:MM"` into sorted, de-duplicated (hour, minute) pairs.
    /// Malformed entries are dropped; an empty result means "unscheduled".
    static func parseTimes(_ raw: String) -> [(hour: Int, minute: Int)] {
        var seen = Set<String>()
        var result: [(hour: Int, minute: Int)] = []
        for part in raw.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let comps = trimmed.split(separator: ":")
            guard comps.count == 2,
                  let hour = Int(comps[0]),
                  let minute = Int(comps[1]),
                  (0 ... 23).contains(hour),
                  (0 ... 59).contains(minute)
            else { continue }
            let key = "\(hour):\(minute)"
            guard seen.insert(key).inserted else { continue }
            result.append((hour, minute))
        }
        return result.sorted { $0.hour == $1.hour ? $0.minute < $1.minute : $0.hour < $1.hour }
    }

    /// Parses `"1,3,5"` into sorted, de-duplicated ISO weekdays (`Mon=1..Sun=7`).
    /// Out-of-range entries are dropped.
    static func parseWeekdays(_ raw: String) -> [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        for part in raw.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let day = Int(trimmed), (1 ... 7).contains(day),
                  seen.insert(day).inserted
            else { continue }
            result.append(day)
        }
        return result.sorted()
    }

    /// Maps an ISO weekday (`Mon=1..Sun=7`) to a Foundation `Calendar`
    /// weekday (`Sunday=1..Saturday=7`): Sunday wraps (`7 → 1`), every other
    /// day shifts by one (`day + 1`). Documented here because the two
    /// conventions collide silently (off-by-one schedules).
    static func calendarWeekday(isoWeekday: Int) -> Int {
        isoWeekday % 7 + 1
    }

    /// Parses an optional `"yyyy-MM-dd"` date (the `endsOn` day, inclusive).
    /// Unparseable input yields nil (no cap), never a crash.
    static func parseDateOnly(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: String(raw.prefix(10)))
    }

    /// First and (optional) last scheduled days for `dueSlots`: the
    /// `courseCreatedAt` day through the earliest of the `durationDays`
    /// window (when > 0) and `endsOn` (inclusive, when parseable). Nil
    /// means the course window is empty (ends before it starts).
    static func scheduleWindow(
        course: MedCourseRecord,
        courseCreatedAt: Date,
        calendar: Calendar = .current
    ) -> (start: Date, last: Date?)? {
        let startDay = calendar.startOfDay(for: courseCreatedAt)
        var lastDay: Date?
        if course.durationDays > 0,
           let end = calendar.date(byAdding: .day, value: course.durationDays - 1, to: startDay) {
            lastDay = end
        }
        if let endsOn = parseDateOnly(course.endsOn) {
            let endsOnDay = calendar.startOfDay(for: endsOn)
            lastDay = min(lastDay ?? endsOnDay, endsOnDay)
        }
        guard lastDay == nil || startDay <= lastDay! else { return nil }
        return (startDay, lastDay)
    }

    /// Collects `times` slots for every applicable day in
    /// `start...min(last, horizonEnd)`, oldest first.
    static func collectSlots(
        times: [(hour: Int, minute: Int)],
        allowedWeekdays: Set<Int>?,
        start: Date,
        last: Date?,
        horizonEnd: Date,
        calendar: Calendar = .current
    ) -> [Date] {
        var slots: [Date] = []
        var day = start
        while day <= horizonEnd {
            if let last, day > last { break }
            let weekday = calendar.component(.weekday, from: day)
            if allowedWeekdays == nil || allowedWeekdays!.contains(weekday) {
                for time in times {
                    if let slot = calendar.date(
                        bySettingHour: time.hour, minute: time.minute, second: 0, of: day
                    ), slot <= horizonEnd {
                        slots.append(slot)
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return slots.sorted()
    }

    /// Wall-clock-local due slots for a course, oldest first.
    ///
    /// - `start` is the `courseCreatedAt` calendar day (slots fire even for
    ///   times earlier that day — a fresh course's first pending flips to
    ///   missed by `autoMiss` once a later slot becomes due, exactly like
    ///   any other past pending).
    /// - `end` is the earliest of: the `durationDays` window from `start`
    ///   (when > 0; `<= 0` means open-ended), `endsOn` (inclusive, when set
    ///   and parseable), and `now + horizonDays`.
    /// - Non-`"active"` courses and `"prn"` courses (log-only, never
    ///   materialized) yield no slots.
    static func dueSlots(
        course: MedCourseRecord,
        courseCreatedAt: Date,
        now: Date,
        horizonDays: Int = 14
    ) -> [Date] {
        guard course.status == "active" else { return [] }
        guard course.scheduleKind == "daily" || course.scheduleKind == "weekdays" else { return [] }
        let times = parseTimes(course.scheduleTimes)
        guard !times.isEmpty else { return [] }
        var allowedWeekdays: Set<Int>?
        if course.scheduleKind == "weekdays" {
            let days = Set(parseWeekdays(course.scheduleWeekdays).map(calendarWeekday(isoWeekday:)))
            guard !days.isEmpty else { return [] }
            allowedWeekdays = days
        }

        let calendar = Calendar.current
        guard let window = scheduleWindow(course: course, courseCreatedAt: courseCreatedAt, calendar: calendar)
        else { return [] }
        let horizonEnd = calendar.date(byAdding: .day, value: horizonDays, to: now) ?? now
        return collectSlots(
            times: times, allowedWeekdays: allowedWeekdays,
            start: window.start, last: window.last, horizonEnd: horizonEnd, calendar: calendar
        )
    }

    // MARK: - Materialize / transitions

    /// Builds the `"pending"` intake rows for slots not already covered by
    /// `existingDueAts` (RFC3339-ms UTC strings). Ids stay empty — the store
    /// assigns them on `createIntake`. `doseSnapshot` is
    /// `"<doseAmount> <doseUnit>"` (trimmed, never rounded: dose stays a string).
    static func materialize(
        courseID: String,
        householdID: String,
        course: MedCourseRecord,
        courseCreatedAt: Date,
        now: Date,
        existingDueAts: Set<String>
    ) -> [IntakeRecord] {
        let dose = "\(course.doseAmount) \(course.doseUnit)".trimmingCharacters(in: .whitespaces)
        return dueSlots(course: course, courseCreatedAt: courseCreatedAt, now: now)
            .map(RFC3339Milli.format)
            .filter { !existingDueAts.contains($0) }
            .map { dueAt in
                IntakeRecord(
                    id: "", householdID: householdID, courseID: courseID, dueAt: dueAt,
                    status: "pending", takenAt: nil, doseSnapshot: dose, note: "",
                    markedBy: "", createdAt: "", updatedAt: ""
                )
            }
    }

    /// Applies the auto-miss rule over a flat intake list (all courses):
    /// a `"pending"` intake whose `dueAt` is past flips to `"missed"` when a
    /// strictly later intake of the SAME course is already due
    /// (`later.dueAt <= now`). "Strictly later" is a dueAt comparison, not a
    /// position comparison, so equal dueAts never miss each other. Everything
    /// else (settled rows, undated PRN logs, pendings with no later due
    /// intake) is returned untouched — past intakes are immutable otherwise.
    static func autoMiss(intakes: [IntakeRecord], now: Date) -> [IntakeRecord] {
        let nowString = RFC3339Milli.format(now)
        return intakes.map { intake in
            guard intake.status == "pending",
                  let dueAt = intake.dueAt,
                  dueAt < nowString
            else { return intake }
            let superseded = intakes.contains { other in
                other.courseID == intake.courseID
                    && other.id != intake.id
                    && (other.dueAt ?? "") > dueAt
                    && (other.dueAt ?? "") <= nowString
            }
            guard superseded else { return intake }
            var flipped = intake
            flipped.status = "missed"
            return flipped
        }
    }

    /// Adherence over an intake list: `taken` counts `"taken"` rows;
    /// `denominator` counts dated (scheduled) rows excluding `"skipped"`.
    /// PRN logs carry no `dueAt`, so a pure-PRN list yields denominator 0
    /// while `taken` still reports the log count.
    static func adherence(intakes: [IntakeRecord]) -> (taken: Int, denominator: Int) {
        let taken = intakes.filter { $0.status == "taken" }.count
        let denominator = intakes.filter { $0.dueAt != nil && $0.status != "skipped" }.count
        return (taken, denominator)
    }

    /// The pendings an early stop must prune: `"pending"` rows with no due
    /// date (defensive — the engine never creates undated pendings) or a
    /// `dueAt` after `now`. Settled rows are never returned.
    static func futurePendings(intakes: [IntakeRecord], now: Date) -> [IntakeRecord] {
        let nowString = RFC3339Milli.format(now)
        return intakes.filter {
            $0.status == "pending" && ($0.dueAt == nil || $0.dueAt! > nowString)
        }
    }
}
