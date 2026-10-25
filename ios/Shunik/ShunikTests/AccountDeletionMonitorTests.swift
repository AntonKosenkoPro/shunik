import Testing
import Foundation
@testable import Shunik

/// Other-device confirmation and cross-account safety (account-deletion spec
/// 6.4/6.7): delayed cleanup with a newly active account erases only the
/// deleted UUID (never B's session, file, Live Activity, or markers), late
/// responses after an account switch converge on the exact UUID, post-purge
/// local failures retain the marker for gate retry, and the generic-rejection
/// monitor erases only after a matched scoped `deleted` verdict.
/// Shared harness: `AccountDeletionTestHarness.swift`.
@MainActor
@Suite("Account deletion monitor", .serialized)
struct AccountDeletionMonitorTests {

    typealias Harness = AccountDeletionHarness
    // MARK: - Cross-account safety

    @Test("delayed cleanup with B active removes only A")
    func delayedCleanupSkipsActiveAccount() async throws {
        let h = makeAccountDeletionHarness()
        signInAccountDeletion(h, accountID: "uB")
        try createAccountDeletionFile(h, "uA")
        try createAccountDeletionFile(h, "uB")
        h.cache.save(CachedSession(id: "uB", email: "b@b.com", emailVerified: true))
        let storage = AccountDeletionStorage(keychain: h.keychain)
        _ = await storage.addCleanupMarker(accountID: "uA")

        await h.coordinator.resume(accountID: "uB")

        #expect(!FileManager.default.fileExists(atPath: accountDeletionFile(h, "uA").path))
        #expect(FileManager.default.fileExists(atPath: accountDeletionFile(h, "uB").path))
        if case .signedIn(let current) = h.sessionStore.state {
            #expect(current.id == "uB")
        } else {
            Issue.record("B must stay signed in")
        }
        #expect(await h.coordinator.pendingCleanupAccounts().isEmpty)
    }

    @Test("late A-status after B signs in erases only A")
    func lateStatusAfterAccountSwitch() async throws {
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
        h.repo.accountStatusResult = AccountStatusResponse(accountID: "uA", state: .deleted)

        #expect(await h.coordinator.resolveIntent() == .cleanedUp)
        #expect(!FileManager.default.fileExists(atPath: accountDeletionFile(h, "uA").path))
        #expect(FileManager.default.fileExists(atPath: accountDeletionFile(h, "uB").path))
        if case .signedIn(let current) = h.sessionStore.state {
            #expect(current.id == "uB")
        } else {
            Issue.record("B must stay signed in")
        }
        #expect(h.cache.load()?.id == "uB")
    }

    @Test("post-purge cleanup failure retains the marker for gate retry")
    func cleanupFailureRetainsMarker() async {
        let h = makeAccountDeletionHarness()
        signInAccountDeletion(h, accountID: "uA")
        await seedAccountDeletionEvidence(h, accountID: "uA")
        // Make ownership unverifiable: snapshot reads fail, so cleanup must
        // stop before clearing auth artifacts and keep the retry marker.
        await h.keychain.setLoadSnapshotError(.storageUnavailable(underlying: "test"))
        h.repo.accountStatusResult = AccountStatusResponse(accountID: "uA", state: .deleted)
        let storage = AccountDeletionStorage(keychain: h.keychain)
        _ = await storage.saveIntent(AccountDeletionIntent(
            accountID: "uA", statusCredential: "status-cap",
            phase: .cleanupRequired, createdAt: Date()
        ))

        #expect(await h.coordinator.resolveIntent() == .cleanupRetryNeeded)
        #expect(await h.coordinator.pendingCleanupAccounts() == ["uA"])
        // Auth artifacts untouched: the app is NOT signed out by a failed
        // cleanup masquerading as success (the gate offers retry instead).
        if case .signedIn(let current) = h.sessionStore.state {
            #expect(current.id == "uA")
        } else {
            Issue.record("failed cleanup must not sign out")
        }
    }

    // MARK: - Other-device monitor

    @Test("monitor confirms deletion only on a matched scoped verdict")
    func monitorConfirmsDeletion() async throws {
        let h = makeAccountDeletionHarness()
        signInAccountDeletion(h, accountID: "uA")
        await h.coordinator.resume(accountID: "uA")
        await seedAccountDeletionEvidence(h, accountID: "uA")
        try createAccountDeletionFile(h, "uA")
        h.repo.accountStatusResult = AccountStatusResponse(accountID: "uA", state: .deleted)

        #expect(await h.coordinator.handleSessionRejection() == .cleanedUp)
        #expect(!FileManager.default.fileExists(atPath: accountDeletionFile(h, "uA").path))
    }

    @Test("monitor preserves on active, inconclusive, or mismatched evidence")
    func monitorPreservesOtherwise() async throws {
        // Active verdict.
        do {
            let h = makeAccountDeletionHarness()
            signInAccountDeletion(h, accountID: "uA")
            await h.coordinator.resume(accountID: "uA")
            await seedAccountDeletionEvidence(h, accountID: "uA")
            try createAccountDeletionFile(h, "uA")
            h.repo.accountStatusResult = AccountStatusResponse(accountID: "uA", state: .active)
            #expect(await h.coordinator.handleSessionRejection() == .preserved)
            #expect(FileManager.default.fileExists(atPath: accountDeletionFile(h, "uA").path))
        }
        // Transport failure.
        do {
            let h = makeAccountDeletionHarness()
            signInAccountDeletion(h, accountID: "uA")
            await h.coordinator.resume(accountID: "uA")
            await seedAccountDeletionEvidence(h, accountID: "uA")
            h.repo.accountStatusError = APIError.offline
            #expect(await h.coordinator.handleSessionRejection() == .preserved)
        }
        // Mismatched UUID.
        do {
            let h = makeAccountDeletionHarness()
            signInAccountDeletion(h, accountID: "uA")
            await h.coordinator.resume(accountID: "uA")
            await seedAccountDeletionEvidence(h, accountID: "uA")
            h.repo.accountStatusResult = AccountStatusResponse(accountID: "uOTHER", state: .deleted)
            #expect(await h.coordinator.handleSessionRejection() == .preserved)
        }
        // No monitored account (explicit sign-out cleared it).
        do {
            let h = makeAccountDeletionHarness()
            #expect(await h.coordinator.handleSessionRejection() == .noMonitoredAccount)
        }
    }

    @Test("generic rejection without evidence locks with files intact")
    func rejectionWithoutEvidencePreserves() async throws {
        let h = makeAccountDeletionHarness()
        signInAccountDeletion(h, accountID: "uA")
        await h.coordinator.resume(accountID: "uA")
        try createAccountDeletionFile(h, "uA")
        #expect(await h.coordinator.handleSessionRejection() == .preserved)
        #expect(FileManager.default.fileExists(atPath: accountDeletionFile(h, "uA").path))
        if case .signedIn = h.sessionStore.state {
        } else {
            Issue.record("session untouched by the monitor itself")
        }
    }
}
