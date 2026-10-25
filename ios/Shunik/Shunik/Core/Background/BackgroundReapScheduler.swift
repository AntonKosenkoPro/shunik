import BackgroundTasks
import Foundation
import OSLog

/// Schedules and registers the widget-stop reap check (live-activities):
/// a `BGAppRefreshTask` that wakes the app in the background so a banner
/// orphaned by a widget Stop (entry saved by `StopTimerIntent`, activity
/// un-endable from the extension) clears without the user opening the app.
///
/// Best-effort throughout: every scheduler call is `try?`/non-throwing,
/// so a background launch never crashes on scheduler errors. No unit
/// tests: `BGTaskScheduler` cannot be driven deterministically in-process
/// (fire timing is OS-determined and registration is process-global), so
/// the reap funnel it invokes (`TimerService.endOrphanedActivities`,
/// including the entry-recency heuristic) is what the suite covers.
enum BackgroundReapScheduler {
    /// The task identifier (also listed in
    /// `BGTaskSchedulerPermittedIdentifiers` in the app plists).
    static let taskIdentifier = "com.antonkosenko.shunik.reap-check"

    private static let logger = Logger(
        subsystem: "com.antonkosenko.shunik",
        category: "BackgroundReapScheduler"
    )

    /// How far out the reap check is requested — a hint only; the OS
    /// fires whenever it decides (typically minutes, never guaranteed).
    private static let rearmDelaySeconds = 60.0

    /// Cancel-then-submit: at most one reap check is ever pending.
    /// Never throws. Simulator/test processes must not schedule real OS
    /// wakes (a pending request outlives the test run and confuses the
    /// runner teardown) — scheduling is device-only behavior.
    static func scheduleReapCheck() {
        #if targetEnvironment(simulator)
        return
        #else
        let center = BGTaskScheduler.shared
        center.cancel(taskRequestWithIdentifier: taskIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: rearmDelaySeconds)
        do {
            try center.submit(request)
        } catch {
            // The submit is the only signal the chain died (e.g. a
            // permitted-identifiers mismatch): record it — a banner that
            // never clears without app contact starts here.
            Self.logger.error("BackgroundReapScheduler: submit failed: \(String(describing: error))")
        }
        #endif
    }

    /// Drops any pending reap check. Never throws.
    static func cancelReapCheck() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    /// Registers the launch handler. Call once (from `AppContainer.init` —
    /// it runs on background launches too). The `reap` closure runs the
    /// Part-A funnel and reports whether the run is still ongoing (draft
    /// present → re-arm the chain; otherwise the chain ends with no
    /// reschedule and the next Start re-arms it).
    static func register(reap: @escaping @Sendable () async -> Bool) {
        #if targetEnvironment(simulator)
        // No real wakes exist here — and registering in a test runner
        // risks the same teardown confusion as scheduling (see above).
        _ = reap
        return
        #else
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            let completion = TaskCompletion(task)
            task.expirationHandler = { completion.complete(success: false) }
            Task {
                let ongoing = await reap()
                if ongoing { scheduleReapCheck() }
                completion.complete(success: true)
            }
        }
        #endif
    }
}

/// Once-only, thread-safe `BGTask` completion. The box crosses into the
/// `Task` above (so it must be `Sendable`), and the guard keeps the
/// expiration handler from double-completing a finished task. The task
/// reference is weak to break the task → expirationHandler → box → task
/// retain cycle (the system holds the task for the duration anyway).
private final class TaskCompletion: @unchecked Sendable {
    private weak var task: BGTask?
    private let lock = NSLock()
    private var done = false

    init(_ task: BGTask) {
        self.task = task
    }

    func complete(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        task?.setTaskCompleted(success: success)
    }
}
