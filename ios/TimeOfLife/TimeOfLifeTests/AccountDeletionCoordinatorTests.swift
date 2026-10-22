import Testing
import Foundation
@testable import TimeOfLife

/// Durable iOS deletion submission and intent resolution
/// (account-deletion spec 6.2/6.6): submit interprets 204/202, ambiguous
/// outcomes stay fenced for scoped resolution, and a restart resumes cleanup
/// without another login. Generic 401/404, malformed responses, offline/5xx,
/// and expired/missing/mismatched evidence NEVER authorize erasure.
/// Shared harness: `AccountDeletionTestHarness.swift`; cross-account and
/// monitor coverage lives in `AccountDeletionMonitorTests`.
@MainActor
@Suite("Account deletion coordinator", .serialized)
struct AccountDeletionCoordinatorTests {

    typealias Harness = AccountDeletionHarness

    // MARK: - Submit

    @Test("204 submit completes, cleans the exact file, and signs out")
    func submit204Completes() async throws {
        let h = makeAccountDeletionHarness()
        signInAccountDeletion(h, accountID: "uA")
        await seedAccountDeletionEvidence(h, accountID: "uA")
        try createAccountDeletionFile(h, "uA")
        try createAccountDeletionFile(h, "uB")
        h.repo.deleteAccountResult = .completed

        #expect(await h.coordinator.submitDeletion(accountID: "uA") == .completed)
        // Exact-UUID cleanup: A's file gone, B's file intact.
        #expect(!FileManager.default.fileExists(atPath: accountDeletionFile(h, "uA").path))
        #expect(FileManager.default.fileExists(atPath: accountDeletionFile(h, "uB").path))
        // Signed out through the gate, navigation reset.
        if case .signedOut = h.sessionStore.state {
        } else {
            Issue.record("expected signed out after confirmed cleanup")
        }
        #expect(h.navigation.path.isEmpty)
        // No Saved face: the draft path discards without an entry.
        #expect(h.live.endedRuns == 0)
        #expect(h.live.endedOrphanedCalls == 1)
        // Intent and markers cleared after durable success.
        if case .success(let intent) = await AccountDeletionStorage(keychain: h.keychain).loadIntent() {
            #expect(intent == nil)
        }
        #expect(await h.coordinator.pendingCleanupAccounts().isEmpty)
    }

    @Test("202 submit reports pending revocation without claiming unlinking")
    func submit202Pending() async throws {
        let h = makeAccountDeletionHarness()
        signInAccountDeletion(h, accountID: "uA")
        await seedAccountDeletionEvidence(h, accountID: "uA")
        h.repo.deleteAccountResult = .pendingAppleRevocation

        #expect(await h.coordinator.submitDeletion(accountID: "uA") == .pendingAppleRevocation)
        #expect(h.coordinator.lastOutcomeWasPendingRevocation)
        if case .signedOut = h.sessionStore.state {
        } else {
            Issue.record("expected signed out after confirmed cleanup")
        }
    }

    @Test("offline submit sends nothing and erases nothing")
    func offlineSubmitSendsNothing() async throws {
        let h = makeAccountDeletionHarness(connected: false)
        signInAccountDeletion(h, accountID: "uA")
        await seedAccountDeletionEvidence(h, accountID: "uA")
        try createAccountDeletionFile(h, "uA")

        #expect(await h.coordinator.submitDeletion(accountID: "uA") == .needsConnection)
        #expect(!h.repo.calls.contains(.deleteAccount))
        #expect(FileManager.default.fileExists(atPath: accountDeletionFile(h, "uA").path))
        if case .signedIn = h.sessionStore.state {
        } else {
            Issue.record("must stay signed in when offline")
        }
    }

    @Test("submit without evidence refuses to send")
    func submitWithoutEvidenceRefused() async {
        let h = makeAccountDeletionHarness()
        signInAccountDeletion(h, accountID: "uA")

        #expect(await h.coordinator.submitDeletion(accountID: "uA") == .missingEvidence)
        #expect(!h.repo.calls.contains(.deleteAccount))
    }

    @Test("intent write failure sends nothing")
    func intentWriteFailureSendsNothing() async {
        let h = makeAccountDeletionHarness()
        signInAccountDeletion(h, accountID: "uA")
        await seedAccountDeletionEvidence(h, accountID: "uA")
        await h.keychain.setDeletionJSONSaveError(
            .storageUnavailable(underlying: "test"), failNextSaves: 10
        )
        // The intent save is the first deletion-JSON write after the
        // evidence read: fail it and the DELETE must never send.
        // (failNextSaves counts all deletion-JSON writes; the evidence seed
        // above already completed, so the next write is the intent.)
        #expect(await h.coordinator.submitDeletion(accountID: "uA") == .storageUnavailable)
        #expect(!h.repo.calls.contains(.deleteAccount))
    }

    @Test("concurrent submits collapse to one send")
    func concurrentSubmitsSingleFlight() async throws {
        let h = makeAccountDeletionHarness()
        signInAccountDeletion(h, accountID: "uA")
        await seedAccountDeletionEvidence(h, accountID: "uA")
        h.repo.deleteAccountResult = .completed
        await h.keychain.setDeletionJSONGateHeld(true)
        let first = Task { await h.coordinator.submitDeletion(accountID: "uA") }
        // The first submit suspends on the intent write; the second must be
        // refused as a duplicate instead of sending again.
        for _ in 0..<100 where !(await h.keychain.deletionJSONGateEntered) {
            await Task.yield()
        }
        #expect(await h.coordinator.submitDeletion(accountID: "uA") == .alreadyInFlight)
        await h.keychain.releaseDeletionJSONGate()
        #expect(await first.value == .completed)
        #expect(h.repo.calls.filter { $0 == .deleteAccount }.count == 1)
    }

    @Test("5xx keeps the fenced intent and claims nothing")
    func failureKeepsFencedIntent() async throws {
        let h = makeAccountDeletionHarness()
        signInAccountDeletion(h, accountID: "uA")
        await seedAccountDeletionEvidence(h, accountID: "uA")
        try createAccountDeletionFile(h, "uA")
        h.repo.deleteAccountError = APIError.server(code: "http_500", message: "boom")

        #expect(await h.coordinator.submitDeletion(accountID: "uA") == .ambiguous)
        // Still signed in, file intact, sync still fenced.
        if case .signedIn = h.sessionStore.state {
        } else {
            Issue.record("must stay signed in on ambiguous outcome")
        }
        #expect(FileManager.default.fileExists(atPath: accountDeletionFile(h, "uA").path))
        #expect(h.syncController.isDeletionFenced(userID: "uA"))
        if case .success(let intent) = await AccountDeletionStorage(keychain: h.keychain).loadIntent() {
            #expect(intent?.accountID == "uA")
        }
    }

    @Test("credential-required asks for same-subject Apple authorization")
    func credentialRequiredAsksApple() async {
        let h = makeAccountDeletionHarness()
        signInAccountDeletion(h, accountID: "uA")
        await seedAccountDeletionEvidence(h, accountID: "uA")
        h.repo.deleteAccountError = APIError.server(code: "apple_credential_required", message: "need token")

        #expect(await h.coordinator.submitDeletion(accountID: "uA") == .appleCredentialRequired)
        if case .signedIn = h.sessionStore.state {
        } else {
            Issue.record("must stay signed in when Apple authorization is required")
        }
    }

    // MARK: - Intent resolution

    @Test("deleted verdict resumes cleanup without another login")
    func deletedVerdictCleansUp() async throws {
        let h = makeAccountDeletionHarness()
        // Signed out (restart after the response was lost): no session, but
        // the fenced intent + evidence survive in the Keychain.
        await seedAccountDeletionEvidence(h, accountID: "uA")
        try createAccountDeletionFile(h, "uA")
        let storage = AccountDeletionStorage(keychain: h.keychain)
        _ = await storage.saveIntent(AccountDeletionIntent(
            accountID: "uA", statusCredential: "status-cap",
            phase: .intentPending, createdAt: Date()
        ))
        h.repo.accountStatusResult = AccountStatusResponse(accountID: "uA", state: .deleted)

        #expect(await h.coordinator.resolveIntent() == .cleanedUp)
        #expect(!FileManager.default.fileExists(atPath: accountDeletionFile(h, "uA").path))
    }

    @Test("active verdict offers explicit retry, never automatic replay")
    func activeVerdictNeedsDecision() async {
        let h = makeAccountDeletionHarness()
        signInAccountDeletion(h, accountID: "uA")
        await seedAccountDeletionEvidence(h, accountID: "uA")
        let storage = AccountDeletionStorage(keychain: h.keychain)
        _ = await storage.saveIntent(AccountDeletionIntent(
            accountID: "uA", statusCredential: "status-cap",
            phase: .intentPending, createdAt: Date()
        ))
        h.repo.accountStatusResult = AccountStatusResponse(accountID: "uA", state: .active)
        h.syncController.setDeletionFence(userID: "uA", fenced: true)

        #expect(await h.coordinator.resolveIntent() == .activeRequiresDecision)
        // No replay was sent and the fence is still held for the decision.
        #expect(!h.repo.calls.contains(.deleteAccount))
        #expect(h.syncController.isDeletionFenced(userID: "uA"))
        if case .signedIn = h.sessionStore.state {
        } else {
            Issue.record("must stay signed in on active verdict")
        }
    }

    @Test("cancel after active resumes exactly one sync owner")
    func cancelResumesSync() async {
        let h = makeAccountDeletionHarness()
        signInAccountDeletion(h, accountID: "uA")
        await seedAccountDeletionEvidence(h, accountID: "uA")
        let storage = AccountDeletionStorage(keychain: h.keychain)
        _ = await storage.saveIntent(AccountDeletionIntent(
            accountID: "uA", statusCredential: "status-cap",
            phase: .intentPending, createdAt: Date()
        ))
        h.syncController.setDeletionFence(userID: "uA", fenced: true)

        await h.coordinator.cancelIntent(accountID: "uA")
        #expect(!h.syncController.isDeletionFenced(userID: "uA"))
        if case .success(let intent) = await storage.loadIntent() {
            #expect(intent == nil)
        }
    }

    @Test("mismatched verdict never applies to another account")
    func mismatchedVerdictPreserves() async throws {
        let h = makeAccountDeletionHarness()
        signInAccountDeletion(h, accountID: "uB")
        await seedAccountDeletionEvidence(h, accountID: "uA")
        try createAccountDeletionFile(h, "uA")
        try createAccountDeletionFile(h, "uB")
        let storage = AccountDeletionStorage(keychain: h.keychain)
        _ = await storage.saveIntent(AccountDeletionIntent(
            accountID: "uA", statusCredential: "status-cap",
            phase: .intentPending, createdAt: Date()
        ))
        h.repo.accountStatusResult = AccountStatusResponse(accountID: "uWRONG", state: .deleted)

        #expect(await h.coordinator.resolveIntent() == .mismatched)
        #expect(FileManager.default.fileExists(atPath: accountDeletionFile(h, "uA").path))
        #expect(FileManager.default.fileExists(atPath: accountDeletionFile(h, "uB").path))
        if case .signedIn(let current) = h.sessionStore.state {
            #expect(current.id == "uB")
        } else {
            Issue.record("B must stay signed in")
        }
    }

    @Test("inconclusive check preserves files with the fence held")
    func inconclusivePreserves() async throws {
        let h = makeAccountDeletionHarness()
        signInAccountDeletion(h, accountID: "uA")
        await seedAccountDeletionEvidence(h, accountID: "uA")
        try createAccountDeletionFile(h, "uA")
        let storage = AccountDeletionStorage(keychain: h.keychain)
        _ = await storage.saveIntent(AccountDeletionIntent(
            accountID: "uA", statusCredential: "status-cap",
            phase: .intentPending, createdAt: Date()
        ))
        h.repo.accountStatusError = APIError.offline
        h.syncController.setDeletionFence(userID: "uA", fenced: true)

        #expect(await h.coordinator.resolveIntent() == .inconclusive)
        #expect(FileManager.default.fileExists(atPath: accountDeletionFile(h, "uA").path))
        #expect(h.syncController.isDeletionFenced(userID: "uA"))
    }
}
