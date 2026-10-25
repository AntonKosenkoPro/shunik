import Foundation
import UserNotifications

/// Whether the OS will deliver reminder notifications.
enum ReminderAuthStatus: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
}

/// Seam over `UNUserNotificationCenter` so the engine is hermetic in tests.
/// All scheduling goes through the engine — kinds never touch this directly
/// (reminder-engine spec: one queue).
protocol ReminderCenter: Sendable {
    func authorization() async -> ReminderAuthStatus
    func requestAuthorization() async -> Bool
    func pendingIDs() async -> Set<String>
    func schedule(id: String, title: String, body: String, dueAt: Date) async throws
    func cancel(ids: [String]) async
}

/// Production center: alert + sound + badge ("both-buzz" household default —
/// the device makes noise unless its local-only mute is on).
final class SystemReminderCenter: ReminderCenter, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()

    func authorization() async -> ReminderAuthStatus {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .authorized, .provisional, .ephemeral:
            return .granted
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func pendingIDs() async -> Set<String> {
        Set(await center.pendingNotificationRequests().map(\.identifier))
    }

    func schedule(id: String, title: String, body: String, dueAt: Date) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Calendar trigger from the absolute due instant: the fire moment is
        // exact; wall-clock slot placement already happened at materialize
        // time (MedicationEngine) or is an absolute appointment (next_due).
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: dueAt
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func cancel(ids: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

/// One derived reminder: a due date with a deterministic cross-device id.
struct ReminderItem: Equatable, Sendable {
    /// `due_<eventID>` for vaccination/grooming next-dues, `intake_<id>` for
    /// pending intakes — any household device cancels by the same id.
    var id: String
    var dueAt: Date
    var petID: String
    var title: String
    var body: String
}

/// The single notification scheduler (reminder-engine spec): derives
/// `(due, pet, title)` from vaccination/grooming `next_due_at` values and
/// pending intakes, keeps a rolling ~14-day window scheduled under the
/// platform cap, and re-tops-up on launch, foreground, data edits, and
/// timezone changes. Snooze is cut for v1 — dues sit pending until marked.
///
/// Per-device mute (`com.shunik.remindersMuted`, never synced): a muted
/// device schedules nothing while the rest of the household stays loud.
@MainActor
final class ReminderEngine: ObservableObject {
    /// How far ahead the engine schedules (rolling window).
    static let windowDays = 14
    /// Hard ceiling under the platform pending-request cap.
    static let maxScheduled = 64
    /// Known engine id prefixes — strays from reinstalls are cancelled.
    static let idPrefixes = ["due_", "intake_"]

    static let mutedKey = "com.shunik.remindersMuted"
    static let askedKey = "com.shunik.remindersAsked"
    static let scheduledKey = "com.shunik.remindersScheduled"

    @Published private(set) var isMuted = false
    @Published private(set) var isAuthorized = false

    private let center: any ReminderCenter
    private let defaults: UserDefaults
    private let store: LocalStore

    init(
        store: LocalStore,
        center: any ReminderCenter = SystemReminderCenter(),
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.defaults = defaults
        self.store = store
        self.isMuted = defaults.bool(forKey: Self.mutedKey)
    }

    /// Reads mute + OS authorization into published state (view entry).
    func loadState() async {
        isMuted = defaults.bool(forKey: Self.mutedKey)
        isAuthorized = await center.authorization() == .granted
    }

    /// Sets the local-only mute (never syncs). Muting clears every pending
    /// request; unmuting re-runs the full top-up on the next refresh.
    func setMuted(_ muted: Bool) async {
        defaults.set(muted, forKey: Self.mutedKey)
        isMuted = muted
        await refresh()
    }

    /// Requests OS permission when undecided. Returns whether delivery is
    /// possible now. Denial is graceful — the caller keeps local dues; the
    /// Settings toggle offers the system Settings path instead.
    func ensurePermission() async -> Bool {
        let status = await center.authorization()
        switch status {
        case .granted:
            isAuthorized = true
            return true
        case .denied:
            isAuthorized = false
            return false
        case .notDetermined:
            let granted = await center.requestAuthorization()
            isAuthorized = granted
            return granted
        }
    }

    /// Called when a due is first created (intake materialized, next-due
    /// saved): asks once, never nags. Later dues rely on the Settings toggle.
    func noteDueCreated() async {
        guard !defaults.bool(forKey: Self.askedKey) else { return }
        defaults.set(true, forKey: Self.askedKey)
        _ = await ensurePermission()
    }

    /// Reconciles the OS pending list with the derived queue: schedules new
    /// and rescheduled dues, cancels resolved and out-of-window ones.
    /// Idempotent and cheap — safe on every foreground/appear/sync pass.
    func refresh() async {
        if defaults.bool(forKey: Self.mutedKey) {
            await clearAllPending()
            return
        }
        let desired: [ReminderItem]
        do {
            desired = try await desiredItems(now: Date())
        } catch {
            return
        }
        let desiredByID = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0) })
        let scheduled = (defaults.dictionary(forKey: Self.scheduledKey) as? [String: String]) ?? [:]
        let pending = await center.pendingIDs()
        let remove = removals(desiredByID: desiredByID, scheduled: scheduled, pending: pending)
        if !remove.isEmpty { await center.cancel(ids: remove) }
        for item in desired.sorted(by: { $0.dueAt < $1.dueAt }) {
            let stamp = Self.stamp(item.dueAt)
            if scheduled[item.id] == stamp { continue }
            do {
                try await center.schedule(id: item.id, title: item.title, body: item.body, dueAt: item.dueAt)
            } catch {
                continue
            }
        }
        let kept = desiredByID.mapValues { Self.stamp($0.dueAt) }
        defaults.set(kept, forKey: Self.scheduledKey)
    }

    /// Muted path: cancel our pending requests and forget the map.
    private func clearAllPending() async {
        let pending = await center.pendingIDs()
        let ours = pending.filter { id in Self.idPrefixes.contains { id.hasPrefix($0) } }
        if !ours.isEmpty { await center.cancel(ids: Array(ours)) }
        defaults.removeObject(forKey: Self.scheduledKey)
    }

    /// Ids to cancel: resolved, rescheduled (same id, new instant), and
    /// strays (our prefixes pending but in neither map — reinstalls).
    private func removals(
        desiredByID: [String: ReminderItem],
        scheduled: [String: String],
        pending: Set<String>
    ) -> [String] {
        var remove: [String] = []
        for id in scheduled.keys where desiredByID[id] == nil {
            remove.append(id)
        }
        for (id, item) in desiredByID {
            if let stamp = scheduled[id], stamp != Self.stamp(item.dueAt) {
                remove.append(id)
            }
        }
        for id in pending where desiredByID[id] == nil
            && Self.idPrefixes.contains(where: { id.hasPrefix($0) }) && !remove.contains(id) {
            remove.append(id)
        }
        return remove
    }

    /// The derived queue: vaccination/grooming next-dues + pending intakes
    /// inside the rolling window, deterministic ids, nearest first, capped.
    /// Throws on store failure (refresh treats it as "try later").
    func desiredItems(now: Date) async throws -> [ReminderItem] {
        let pets = try await store.listPets()
        let names = Dictionary(uniqueKeysWithValues: pets.map { ($0.id, $0.name) })
        let multiPet = pets.count > 1
        let horizon = now.addingTimeInterval(TimeInterval(Self.windowDays * 24 * 3600))
        var items: [ReminderItem] = []
        let events = try await store.listAllEvents()
        items += eventDues(events: events, names: names, multiPet: multiPet, horizon: horizon)
        for event in events {
            guard event.kind == "med_course", let course = event.course, course.status == "active" else { continue }
            let intakes = (try? await store.listIntakes(courseID: event.id)) ?? []
            items += intakeDues(
                event: event, courseName: course.drugName, intakes: intakes,
                names: names, multiPet: multiPet, horizon: horizon
            )
        }
        return Array(items.sorted { $0.dueAt < $1.dueAt }.prefix(Self.maxScheduled))
    }

    /// Next-due reminders for vaccination/grooming events.
    private func eventDues(
        events: [EventRecord], names: [String: String], multiPet: Bool, horizon: Date
    ) -> [ReminderItem] {
        var items: [ReminderItem] = []
        for event in events {
            guard event.kind == "vaccination" || event.kind == "grooming",
                  let dueString = event.nextDueAt,
                  let dueAt = RFC3339Milli.parse(dueString),
                  dueAt <= horizon else { continue }
            let detail = event.kind == "vaccination"
                ? event.vaccination?.vaccine ?? ""
                : event.grooming?.service ?? ""
            items.append(ReminderItem(
                id: "due_\(event.id)",
                dueAt: dueAt,
                petID: event.petID,
                title: event.title,
                body: Self.prefixed(pet: names[event.petID], multiPet: multiPet, detail: detail)
            ))
        }
        return items
    }

    /// Pending-intake reminders for one active course.
    private func intakeDues(
        event: EventRecord,
        courseName: String,
        intakes: [IntakeRecord],
        names: [String: String],
        multiPet: Bool,
        horizon: Date
    ) -> [ReminderItem] {
        var items: [ReminderItem] = []
        for intake in intakes {
            guard intake.status == "pending",
                  let dueString = intake.dueAt,
                  let dueAt = RFC3339Milli.parse(dueString),
                  dueAt <= horizon else { continue }
            items.append(ReminderItem(
                id: "intake_\(intake.id)",
                dueAt: dueAt,
                petID: event.petID,
                title: courseName,
                body: Self.prefixed(pet: names[event.petID], multiPet: multiPet, detail: intake.doseSnapshot)
            ))
        }
        return items
    }

    // MARK: - Formatting

    /// Single-pet feel (pet-events spec): no pet prefix with one pet.
    static func prefixed(pet: String?, multiPet: Bool, detail: String) -> String {
        guard multiPet, let pet, !pet.isEmpty else { return detail }
        return detail.isEmpty ? pet : "\(pet) • \(detail)"
    }

    static func stamp(_ date: Date) -> String {
        String(Int64(date.timeIntervalSince1970 * 1000))
    }
}
