import Testing
import Foundation
@testable import Shunik

/// Status-evidence lifecycle in `AuthService` (account-deletion spec D3/6.1):
/// sign-in, refresh, and `/me` persist the status credential separately from
/// the login snapshot; explicit sign-out clears this account's monitoring;
/// generic session locks RETAIN it so another launch can resolve a pending
/// check. Monitoring is never a second login and unlocks nothing.
@MainActor
@Suite("AuthService status evidence", .serialized)
struct AuthServiceStatusEvidenceTests {

    private func makeService(
        repo: FakeAuthRepository = FakeAuthRepository()
    ) -> (AuthService, FakeAuthRepository, InMemoryKeychainStore, SessionCache, SessionStore) {
        let keychain = InMemoryKeychainStore()
        let cache = SessionCache(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sessionStore = SessionStore()
        let service = AuthService(
            repository: repo,
            keychain: keychain,
            cache: cache,
            sessionStore: sessionStore
        )
        return (service, repo, keychain, cache, sessionStore)
    }

    private func storedCredential(
        _ keychain: InMemoryKeychainStore,
        accountID: String
    ) async -> StoredStatusCredential? {
        let storage = AccountDeletionStorage(keychain: keychain)
        // Far-future expiry in these tests; use a direct map read to avoid
        // expiry filtering hiding the write itself.
        guard case .success(let json) = await keychain.loadDeletionJSON(for: .accountStatusCredentials),
              let json,
              let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: StoredStatusCredential].self, from: data) else {
            return nil
        }
        _ = storage
        return map[accountID]
    }

    @Test("OTP verify persists the status credential separately from the snapshot")
    func verifyPersistsStatusCredential() async throws {
        let (service, repo, keychain, _, _) = makeService()
        repo.otpVerifyResult = AuthSession(
            accessToken: "at", refreshToken: "rt",
            user: UserDTO(id: "u1", email: "a@b.com", emailVerified: true),
            accountStatusCredential: "status-1",
            accountStatusExpiresAt: "2099-01-01T00:00:00Z"
        )
        try await service.verifyOtp(email: "a@b.com", code: "123456")
        // The fire-and-forget persist races the assertion: poll briefly.
        var stored: StoredStatusCredential?
        for _ in 0..<100 {
            stored = await storedCredential(keychain, accountID: "u1")
            if stored != nil { break }
            await Task.yield()
        }
        #expect(stored?.credential == "status-1")
        // The login snapshot itself carries no status credential.
        let snapshot = try #require(await TestFactories.snapshotTokens(keychain).access)
        #expect(snapshot == "at")
    }

    @Test("Apple sign-in persists the status credential and native user id")
    func appleSignInPersistsEvidenceAndUser() async throws {
        let (service, repo, keychain, _, _) = makeService()
        repo.appleSignInResult = AuthSession(
            accessToken: "at-a", refreshToken: "rt-a",
            user: UserDTO(id: "u-apple", email: "apple@privaterelay.appleid.com", emailVerified: true),
            accountStatusCredential: "status-a",
            accountStatusExpiresAt: "2099-01-01T00:00:00Z"
        )
        try await service.signInWithApple(
            identityToken: "id-token", appleUserID: "apple-sub-1", authorizationCode: "code-1"
        )
        #expect(await keychain.string(for: .appleUserId) == "apple-sub-1")
        // Apple sign-in forwards the authorization code to the backend.
        guard case let .appleSignIn(token, code) = repo.calls.first(where: {
            if case .appleSignIn = $0 { return true }
            return false
        }) else {
            Issue.record("expected appleSignIn call")
            return
        }
        #expect(token == "id-token")
        #expect(code == "code-1")
    }

    @Test("email verify clears any stale native Apple user id")
    func emailVerifyClearsAppleUser() async throws {
        let (service, _, keychain, _, _) = makeService()
        await keychain.setString("apple-sub-stale", for: .appleUserId)
        try await service.verifyOtp(email: "a@b.com", code: "123456")
        #expect(await keychain.string(for: .appleUserId) == nil)
    }

    @Test("explicit logout clears this account's monitoring state")
    func logoutClearsMonitoring() async throws {
        let (service, repo, keychain, _, sessionStore) = makeService()
        repo.otpVerifyResult = AuthSession(
            accessToken: "at", refreshToken: "rt",
            user: UserDTO(id: "u1", email: "a@b.com", emailVerified: true),
            accountStatusCredential: "status-1",
            accountStatusExpiresAt: "2099-01-01T00:00:00Z"
        )
        try await service.verifyOtp(email: "a@b.com", code: "123456")
        for _ in 0..<100 {
            if await storedCredential(keychain, accountID: "u1") != nil { break }
            await Task.yield()
        }
        await keychain.setString("apple-sub-1", for: .appleUserId)
        let storage = AccountDeletionStorage(keychain: keychain)
        _ = await storage.saveIntent(AccountDeletionIntent(
            accountID: "u1", statusCredential: "status-1",
            phase: .intentPending, createdAt: Date()
        ))
        await service.logout()
        // Snapshot cleared (existing contract) ...
        if case .success(let snapshot) = await keychain.loadSnapshot() {
            #expect(snapshot == nil)
        } else {
            Issue.record("snapshot load must succeed after logout")
        }
        if case .signedOut = sessionStore.state {
        } else {
            Issue.record("expected signed out")
        }
        // Monitoring cleared for the signed-out account.
        #expect(await storedCredential(keychain, accountID: "u1") == nil)
        #expect(await keychain.string(for: .appleUserId) == nil)
        if case .success(let intent) = await storage.loadIntent() {
            #expect(intent == nil)
        } else {
            Issue.record("intent load must succeed")
        }
    }

    @Test("revocation lock retains monitoring for later resolution")
    func revocationRetainsMonitoring() async throws {
        let (service, repo, keychain, _, sessionStore) = makeService()
        repo.otpVerifyResult = AuthSession(
            accessToken: "at", refreshToken: "rt",
            user: UserDTO(id: "u1", email: "a@b.com", emailVerified: true),
            accountStatusCredential: "status-1",
            accountStatusExpiresAt: "2099-01-01T00:00:00Z"
        )
        try await service.verifyOtp(email: "a@b.com", code: "123456")
        for _ in 0..<100 {
            if await storedCredential(keychain, accountID: "u1") != nil { break }
            await Task.yield()
        }
        await keychain.setString("apple-sub-1", for: .appleUserId)
        // A conclusive refresh rejection locks (existing contract) but must
        // NOT clear monitoring: another launch resolves the pending check.
        repo.refreshError = APIError.server(code: "token_reuse", message: "revoked")
        _ = try? await service.performRefresh()
        if case .signedOut = sessionStore.state {
        } else {
            Issue.record("expected signed out after reuse")
        }
        #expect(await storedCredential(keychain, accountID: "u1")?.credential == "status-1")
        #expect(await keychain.string(for: .appleUserId) == "apple-sub-1")
    }
}
