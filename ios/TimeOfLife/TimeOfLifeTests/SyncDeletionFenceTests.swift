import Testing
import Foundation
@testable import TimeOfLife

/// Deletion fencing in `SyncController` (account-deletion spec + sync-client
/// D-fence): while a deletion outcome is unresolved (or cleanup is removing
/// the account), the target account runs no drain and no pull. A timeout
/// never lifts the fence — only a scoped verdict or explicit cancel does.
/// Late responses are guarded by account and never merge into another
/// account.
@MainActor
@Suite("Sync deletion fence", .serialized)
struct SyncDeletionFenceTests {

    private func makeContext(
        connected: Bool = true
    ) -> (store: LocalStore, controller: SyncController) {
        // swiftlint:disable:next force_try
        let store = try! LocalStore(url: temporaryStoreURL())
        let connectivity = MockConnectivity(connected: connected)
        let controller = SyncController(
            store: store,
            connectivity: connectivity
        ) { "u1" }
        return (store, controller)
    }

    private func temporaryStoreURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(LocalStore.databaseFileName(userID: "u1"))
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test("fence is account-scoped and observable")
    func fenceIsAccountScoped() {
        let (_, controller) = makeContext()
        #expect(!controller.isDeletionFenced(userID: "u1"))
        controller.setDeletionFence(userID: "u1", fenced: true)
        #expect(controller.isDeletionFenced(userID: "u1"))
        #expect(!controller.isDeletionFenced(userID: "u2"))
        controller.setDeletionFence(userID: "u1", fenced: false)
        #expect(!controller.isDeletionFenced(userID: "u1"))
    }

    @Test("activate under fence parks as inactive without draining")
    func activateUnderFenceParksInactive() async {
        let (_, controller) = makeContext()
        controller.setDeletionFence(userID: "u1", fenced: true)
        controller.activate(userID: "u1")
        await waitUntil {
            if case .syncing = controller.status { return false }
            return true
        }
        if case .inactive = controller.status {
        } else {
            Issue.record("fenced activate must park as inactive, got \(controller.status)")
        }
    }

    @Test("syncNow and trigger are refused while fenced")
    func manualAndAutoTriggersRefused() async {
        let (_, controller) = makeContext()
        controller.activate(userID: "u1")
        await waitUntil {
            if case .idle = controller.status { return true }
            return false
        }
        controller.setDeletionFence(userID: "u1", fenced: true)
        await controller.syncNow(userID: "u1")
        controller.trigger(userID: "u1")
        // Refused triggers leave no cycle behind: status is untouched and
        // no new owner was forked.
        #expect(!controller.isCycleLive)
    }

    @Test("releasing the fence and activating resumes exactly one owner")
    func releaseAndActivateResumes() async {
        let (_, controller) = makeContext()
        controller.setDeletionFence(userID: "u1", fenced: true)
        controller.activate(userID: "u1")
        await waitUntil {
            if case .inactive = controller.status { return true }
            return false
        }
        controller.setDeletionFence(userID: "u1", fenced: false)
        controller.activate(userID: "u1")
        await waitUntil {
            if case .idle = controller.status { return true }
            if case .error = controller.status { return true }
            return false
        }
        if case .syncing = controller.status {
            Issue.record("cycle must have settled after release")
        }
    }

    @Test("fence for another account does not block this one")
    func otherAccountFenceIgnored() async {
        let (_, controller) = makeContext()
        controller.setDeletionFence(userID: "u2", fenced: true)
        controller.activate(userID: "u1")
        await waitUntil {
            if case .syncing = controller.status { return false }
            return true
        }
        if case .inactive = controller.status {
            Issue.record("unrelated fence must not park this account")
        }
    }
}
