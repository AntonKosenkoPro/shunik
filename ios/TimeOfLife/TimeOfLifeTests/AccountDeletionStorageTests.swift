import Testing
import Foundation
@testable import TimeOfLife

/// Durable deletion artifacts (account-deletion spec 6.1): separate
/// account-keyed Keychain items for status credentials, the pending intent,
/// and cleanup markers. Absent vs storage-unavailable are distinguished —
/// unavailable never reads as "nothing scheduled".
@Suite("AccountDeletionStorage")
struct AccountDeletionStorageTests {

    private func makeStorage() -> (AccountDeletionStorage, InMemoryKeychainStore) {
        let keychain = InMemoryKeychainStore()
        return (AccountDeletionStorage(keychain: keychain), keychain)
    }

    // MARK: - Status credentials

    @Test("missing credential loads as nil, not failure")
    func missingCredentialIsNil() async {
        let (storage, _) = makeStorage()
        guard case .success(let stored) = await storage.loadStatusCredential(accountID: "a") else {
            Issue.record("expected success")
            return
        }
        #expect(stored == nil)
    }

    @Test("round-trips one account credential with expiry")
    func roundTripCredential() async {
        let (storage, _) = makeStorage()
        guard case .success = await storage.saveStatusCredential("cred-a", expiresAt: "2099-01-01T00:00:00Z", accountID: "a") else {
            Issue.record("expected save success")
            return
        }
        guard case .success(let stored) = await storage.loadStatusCredential(accountID: "a") else {
            Issue.record("expected load success")
            return
        }
        #expect(stored?.credential == "cred-a")
        #expect(stored?.expiresAt == "2099-01-01T00:00:00Z")
    }

    @Test("credentials are account-keyed and independent")
    func credentialsAreAccountKeyed() async {
        let (storage, _) = makeStorage()
        _ = await storage.saveStatusCredential("cred-a", expiresAt: "2099-01-01T00:00:00Z", accountID: "a")
        _ = await storage.saveStatusCredential("cred-b", expiresAt: "2099-01-01T00:00:00Z", accountID: "b")
        guard case .success(let storedA) = await storage.loadStatusCredential(accountID: "a"),
              case .success(let storedB) = await storage.loadStatusCredential(accountID: "b") else {
            Issue.record("expected load success")
            return
        }
        #expect(storedA?.credential == "cred-a")
        #expect(storedB?.credential == "cred-b")
    }

    @Test("removing one account keeps the other")
    func removeOneKeepsOther() async {
        let (storage, _) = makeStorage()
        _ = await storage.saveStatusCredential("cred-a", expiresAt: "2099-01-01T00:00:00Z", accountID: "a")
        _ = await storage.saveStatusCredential("cred-b", expiresAt: "2099-01-01T00:00:00Z", accountID: "b")
        await storage.removeStatusCredential(accountID: "a")
        guard case .success(let storedA) = await storage.loadStatusCredential(accountID: "a"),
              case .success(let storedB) = await storage.loadStatusCredential(accountID: "b") else {
            Issue.record("expected load success")
            return
        }
        #expect(storedA == nil)
        #expect(storedB?.credential == "cred-b")
    }

    @Test("expired credential reads as absent")
    func expiredCredentialIsAbsent() async {
        let (storage, _) = makeStorage()
        _ = await storage.saveStatusCredential("cred-old", expiresAt: "2001-01-01T00:00:00Z", accountID: "a")
        guard case .success(let stored) = await storage.loadStatusCredential(accountID: "a") else {
            Issue.record("expected load success")
            return
        }
        #expect(stored == nil)
    }

    @Test("missing expiry reads as absent")
    func missingExpiryIsAbsent() async {
        let (storage, _) = makeStorage()
        _ = await storage.saveStatusCredential("cred-noexp", expiresAt: nil, accountID: "a")
        guard case .success(let stored) = await storage.loadStatusCredential(accountID: "a") else {
            Issue.record("expected load success")
            return
        }
        #expect(stored == nil)
    }

    @Test("unparsable expiry reads as absent")
    func unparsableExpiryIsAbsent() async {
        let (storage, _) = makeStorage()
        _ = await storage.saveStatusCredential("cred-bad", expiresAt: "not-a-date", accountID: "a")
        guard case .success(let stored) = await storage.loadStatusCredential(accountID: "a") else {
            Issue.record("expected load success")
            return
        }
        #expect(stored == nil)
    }

    @Test("Keychain failure surfaces instead of absent")
    func storageFailureIsFailure() async {
        let (storage, keychain) = makeStorage()
        await keychain.setDeletionJSONLoadError(.storageUnavailable(underlying: "test"))
        let result = await storage.loadStatusCredential(accountID: "a")
        guard case .failure = result else {
            Issue.record("expected failure, not absent")
            return
        }
    }

    @Test("corrupt JSON reads as unavailable, never absent")
    func corruptJSONIsUnavailable() async {
        let keychain = InMemoryKeychainStore()
        _ = await keychain.saveDeletionJSON("{{{not json", for: .accountStatusCredentials)
        let result = await AccountDeletionStorage(keychain: keychain).loadStatusCredential(accountID: "a")
        guard case .failure = result else {
            Issue.record("expected failure, not absent")
            return
        }
    }

    // MARK: - Pending intent

    @Test("intent round-trips with phase")
    func intentRoundTrip() async {
        let (storage, _) = makeStorage()
        let intent = AccountDeletionIntent(
            accountID: "a", statusCredential: "cred-a",
            phase: .intentPending, createdAt: Date(timeIntervalSince1970: 1_000)
        )
        guard case .success = await storage.saveIntent(intent) else {
            Issue.record("expected save success")
            return
        }
        guard case .success(let loaded) = await storage.loadIntent() else {
            Issue.record("expected load success")
            return
        }
        #expect(loaded == intent)
    }

    @Test("missing intent loads as nil")
    func missingIntentIsNil() async {
        let (storage, _) = makeStorage()
        guard case .success(let loaded) = await storage.loadIntent() else {
            Issue.record("expected success")
            return
        }
        #expect(loaded == nil)
    }

    @Test("clearIntent removes the intent")
    func clearIntentRemoves() async {
        let (storage, _) = makeStorage()
        let intent = AccountDeletionIntent(
            accountID: "a", statusCredential: "cred-a",
            phase: .cleanupRequired, createdAt: Date(timeIntervalSince1970: 1_000)
        )
        _ = await storage.saveIntent(intent)
        await storage.clearIntent()
        guard case .success(let loaded) = await storage.loadIntent() else {
            Issue.record("expected success")
            return
        }
        #expect(loaded == nil)
    }

    // MARK: - Cleanup markers

    @Test("markers accumulate and remove individually")
    func markersAccumulateAndRemove() async {
        let (storage, _) = makeStorage()
        _ = await storage.addCleanupMarker(accountID: "a")
        _ = await storage.addCleanupMarker(accountID: "b")
        _ = await storage.addCleanupMarker(accountID: "a")
        guard case .success(let markers) = await storage.loadCleanupMarkers() else {
            Issue.record("expected load success")
            return
        }
        #expect(markers.sorted() == ["a", "b"])
        await storage.removeCleanupMarker(accountID: "a")
        guard case .success(let remaining) = await storage.loadCleanupMarkers() else {
            Issue.record("expected load success")
            return
        }
        #expect(remaining == ["b"])
    }

    @Test("missing markers load as empty")
    func missingMarkersAreEmpty() async {
        let (storage, _) = makeStorage()
        guard case .success(let markers) = await storage.loadCleanupMarkers() else {
            Issue.record("expected success")
            return
        }
        #expect(markers.isEmpty)
    }
}
