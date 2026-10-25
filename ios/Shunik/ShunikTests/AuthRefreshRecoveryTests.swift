// swiftlint:disable file_length
import Testing
import Foundation
@testable import Shunik

/// Durable refresh-attempt lifecycle (fix-refresh-response-loss 3.4):
/// truncated-commit reclaim, restart mid-replacement, stale-completion drop,
/// single-flight sharing (in AuthServiceTests), closed-duplicate ignore, and
/// genuine-reuse revocation — all driven by `FakeAuthRepository`'s
/// attempt-aware canned server.
@MainActor
@Suite("AuthRefreshRecovery")
struct AuthRefreshRecoveryTests {

    private func makeService(
        initialSnapshot: CredentialSnapshot? = nil,
        cached: CachedSession? = nil
    ) -> (AuthService, FakeAuthRepository, InMemoryKeychainStore, SessionCache, SessionStore) {
        let repo = FakeAuthRepository()
        let keychain = InMemoryKeychainStore(snapshot: initialSnapshot)
        let cache = SessionCache(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        if let cached { cache.save(cached) }
        let store = SessionStore()
        let service = AuthService(
            repository: repo,
            keychain: keychain,
            cache: cache,
            sessionStore: store
        )
        return (service, repo, keychain, cache, store)
    }

    private func tokens(_ keychain: InMemoryKeychainStore) async -> (access: String?, refresh: String?) {
        let snapshot = await TestFactories.snapshotTokens(keychain)
        return (snapshot.access, snapshot.refresh)
    }

    private func waitForRefreshSend(_ repo: FakeAuthRepository) async throws {
        try await TestFactories.waitForRefreshSend(repo)
    }

    @Test("performRefresh mints a fresh attempt per logical rotation")
    func performRefreshRotatesAttempts() async throws {
        let (service, repo, _, _, _) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt")
        )

        _ = try await service.performRefresh()
        _ = try await service.performRefresh()

        #expect(repo.refreshSends.count == 2)
        let attempts = repo.refreshSends.map(\.attemptId)
        #expect(Set(attempts).count == 2, "each committed rotation consumes its attempt")
    }

    @Test("restoreSession never starts its own refresh: one protected request has one refresh owner")
    func restoreDoesNotStartOwnRefresh() async throws {
        let cached = CachedSession(id: "u1", email: "a@b.com", emailVerified: true)
        let (service, repo, keychain, _, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt"),
            cached: cached
        )
        // In production the single transparent refresh lives inside APIClient
        // and runs before restore ever sees the 401. The Fake answers `me`
        // directly, so a 401 here means that owned refresh conclusively
        // failed with no rotation landed: restore must lock the gate WITHOUT
        // sending a second blind refresh of its own.
        repo.meError = APIError.unauthorized

        await service.restoreSession()

        #expect(repo.refreshSends.isEmpty, "restore must not send its own refresh")
        #expect(await tokens(keychain) == (nil, nil))
        #expect(store.state == .signedOut)
    }

    @Test("restoreSession keeps the session when a rotation landed under the 401")
    func restoreKeepsSessionWhenRotationLanded() async throws {
        let cached = CachedSession(id: "u1", email: "a@b.com", emailVerified: true)
        let (service, repo, keychain, _, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "entry-at", refreshToken: "entry-rt"),
            cached: cached
        )
        // Simulates the owned refresh having rotated the snapshot before the
        // retried request still 401d: wiping here would nuke fresh credentials.
        repo.meHook = {
            _ = await keychain.saveSnapshot(
                TestFactories.makeSnapshot(accessToken: "rot-at", refreshToken: "rot-rt")
            )
        }
        repo.meError = APIError.unauthorized

        await service.restoreSession()

        #expect(store.state == .signedIn(cached))
        #expect(await tokens(keychain) == ("rot-at", "rot-rt"))
    }

    @Test("restoreSession keeps the cached session when credential storage is unavailable")
    func restoreKeepsCachedOnStorageFailure() async throws {
        let cached = CachedSession(id: "u1", email: "a@b.com", emailVerified: true)
        let (service, repo, keychain, _, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt"),
            cached: cached
        )
        await keychain.setLoadSnapshotError(.storageUnavailable(underlying: "test"))

        await service.restoreSession()

        // "Unavailable, keep retry intent" — not "no session".
        #expect(store.state == .signedIn(cached))
        #expect(repo.calls.isEmpty, "no network traffic when credentials are unreadable")
    }

    @Test("truncated commit is reclaimed via the same attempt")
    func truncatedCommitReclaimedViaSameAttempt() async throws {
        let (service, repo, keychain, _, _) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt")
        )
        repo.attemptAwareServerEnabled = true
        // The server commits the rotation but the response never arrives.
        repo.dropNextAttemptResponse = true

        do {
            _ = try await service.performRefresh()
            Issue.record("Expected the truncated response to throw")
        } catch let error as APIError {
            #expect(error == .transport(underlying: "simulated truncated refresh response"))
        }

        // Predecessor + attempt retained: nothing half-written published.
        #expect(await tokens(keychain) == ("at", "rt"))
        let pending = await TestFactories.snapshotTokens(keychain).attempt
        let firstAttempt = try #require(pending)
        #expect(repo.refreshSends.map(\.attemptId) == [firstAttempt])

        // The retry reuses the same predecessor + attempt and reclaims the
        // SAME successor instead of rotating forward.
        let recovered = try await service.performRefresh()

        #expect(recovered == "rec-at-1")
        #expect(repo.refreshSends.map(\.attemptId) == [firstAttempt, firstAttempt])
        #expect(await tokens(keychain) == ("rec-at-1", "rec-rt-1"))
        #expect(await TestFactories.snapshotTokens(keychain).attempt == nil)
    }

    @Test("restart mid-replacement resumes the same attempt, never a mixed pair")
    func restartMidReplacement() async throws {
        let keychain = InMemoryKeychainStore(
            snapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt")
        )
        let repo = FakeAuthRepository()
        repo.attemptAwareServerEnabled = true
        repo.dropNextAttemptResponse = true
        let firstService = AuthService(
            repository: repo,
            keychain: keychain,
            cache: SessionCache(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            sessionStore: SessionStore()
        )
        do {
            _ = try await firstService.performRefresh()
            Issue.record("Expected the truncated response to throw")
        } catch is APIError {
            // Expected: the committed rotation's response never arrived.
        }

        // The process "restarts": a fresh service over the same Keychain and
        // the same (surviving) server state retries the rotation.
        let restarted = AuthService(
            repository: repo,
            keychain: keychain,
            cache: SessionCache(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            sessionStore: SessionStore()
        )
        let recovered = try await restarted.performRefresh()

        let sends = repo.refreshSends
        #expect(sends.count == 2)
        #expect(sends[0].attemptId == sends[1].attemptId, "restart reuses the persisted attempt")
        #expect(sends[1].refreshToken == "rt", "restart retries the persisted predecessor")
        #expect(recovered == "rec-at-1")
        // Either the predecessor pair or the complete successor pair — never mixed.
        #expect(await tokens(keychain) == ("rec-at-1", "rec-rt-1"))
    }

    @Test("stale completion after account switch never writes into the new session")
    func staleCompletionDroppedAfterSwitch() async throws {
        let (service, repo, keychain, _, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(
                accessToken: "at-A", refreshToken: "rt-A", accountId: "uA"
            )
        )
        repo.refreshGateHeld = true

        let pending = Task { try await service.performRefresh() }
        try await waitForRefreshSend(repo)

        // Account switch lands mid-flight: logout clears, then B signs in.
        await service.logout()
        repo.otpVerifyResult = AuthSession(
            accessToken: "at-B",
            refreshToken: "rt-B",
            user: UserDTO(id: "uB", email: "b@c.com", emailVerified: true)
        )
        try await service.verifyOtp(email: "b@c.com", code: "123456")
        repo.releaseRefreshGate()

        // A's late completion is dropped, not applied and not cleared.
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await tokens(keychain) == ("at-B", "rt-B"))
        guard case let .signedIn(session) = store.state else {
            Issue.record("expected the new session to survive, got \(store.state)")
            return
        }
        #expect(session.id == "uB")
    }

    @Test("stale completion after sign-out keeps the gate locked")
    func staleCompletionDroppedAfterSignOut() async throws {
        let (service, repo, keychain, _, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt")
        )
        repo.refreshGateHeld = true

        let pending = Task { try await service.performRefresh() }
        try await waitForRefreshSend(repo)

        await service.logout()
        repo.releaseRefreshGate()

        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(store.state == .signedOut)
        #expect(await tokens(keychain) == (nil, nil))
    }

    @Test("a refresh after sign-out starts a fresh attempt instead of joining the stale task")
    func refreshAfterSignOutDoesNotJoinStaleTask() async throws {
        let (service, repo, _, _, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at-A", refreshToken: "rt-A")
        )
        repo.refreshGateHeld = true

        let stale = Task { try await service.performRefresh() }
        try await waitForRefreshSend(repo)

        // Sign-out lands mid-flight, then a new session starts while the
        // stale task is still unwinding.
        await service.logout()
        repo.otpVerifyResult = AuthSession(
            accessToken: "at-B",
            refreshToken: "rt-B",
            user: UserDTO(id: "uB", email: "b@c.com", emailVerified: true)
        )
        try await service.verifyOtp(email: "b@c.com", code: "123456")

        // The new generation must not join the stale task: it sends its own
        // refresh with its own attempt.
        let fresh = Task { try await service.performRefresh() }
        try await TestFactories.waitForRefreshSends(repo, count: 2)
        repo.releaseRefreshGate()

        await #expect(throws: CancellationError.self) { try await stale.value }
        let token = try await fresh.value
        #expect(!token.isEmpty)
        let attempts = repo.refreshSends.map(\.attemptId)
        #expect(Set(attempts).count == 2, "stale and fresh rotations must not share an attempt")
        guard case .signedIn = store.state else {
            Issue.record("expected the fresh session to publish, got \(store.state)")
            return
        }
    }

    @Test("logout during durable publish does not resurrect the signed-out session")
    func noPublishAfterLogoutMidSave() async throws {
        let (service, repo, keychain, _, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt")
        )
        // Hold the network first so the intent save (which precedes the
        // send) completes ungated; arm the save gate only after the send
        // is recorded, then let the response through into the gated save.
        repo.refreshGateHeld = true

        let pending = Task { try await service.performRefresh() }
        try await waitForRefreshSend(repo)
        await keychain.setSaveGateHeld(true)
        repo.releaseRefreshGate()
        // The response is back; the task now suspends inside the durable
        // save. Interleave sign-out exactly there.
        try await TestFactories.waitForSaveGate(keychain)
        await service.logout()
        await keychain.releaseSaveGate()

        // The superseded publish is dropped: the gate stays locked even
        // though the save itself succeeded.
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(store.state == .signedOut)
    }

    @Test("closed duplicate is ignored: current credentials survive")
    func closedDuplicateIgnored() async throws {
        let (service, repo, keychain, cache, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "cur-at", refreshToken: "cur-rt"),
            cached: CachedSession(id: "u1", email: "a@b.com", emailVerified: true)
        )
        // A delayed duplicate of a closed attempt: never revocation.
        repo.refreshError = APIError.server(code: "refresh_attempt_completed", message: "Attempt already completed")

        let token = try await service.performRefresh()

        #expect(token == "cur-at", "caller continues with the durable credentials")
        #expect(await tokens(keychain) == ("cur-at", "cur-rt"))
        #expect(cache.load()?.id == "u1")
        #expect(store.state == .signedOut, "no spurious state change on an ignored duplicate")
    }

    @Test("genuine reuse still revokes the session")
    func genuineReuseRevokes() async throws {
        let cached = CachedSession(id: "u1", email: "a@b.com", emailVerified: true)
        let (service, repo, keychain, cache, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt"),
            cached: cached
        )
        repo.attemptAwareServerEnabled = true

        // A committed rotation revokes the predecessor server-side...
        _ = try await service.performRefresh()
        #expect(await tokens(keychain) == ("rec-at-1", "rec-rt-1"))

        // ...then a stale client presents that revoked predecessor with a
        // DIFFERENT attempt: reuse, not recovery.
        _ = await keychain.saveSnapshot(TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt"))
        do {
            _ = try await service.performRefresh()
            Issue.record("Expected token_reuse to throw")
        } catch let error as APIError {
            #expect(error.code == "token_reuse")
        }

        #expect(await tokens(keychain) == (nil, nil))
        #expect(cache.load() == nil)
        #expect(store.state == .signedOut)
    }

    @Test(
        "ambiguous refresh failures keep credentials and retry intent",
        arguments: [
            APIError.offline,
            APIError.transport(underlying: "connection reset"),
            APIError.decoding(underlying: "truncated body"),
            APIError.server(code: "http_500", message: "Internal server error"),
        ]
    )
    func ambiguousFailuresKeepRetryIntent(error: APIError) async throws {
        let cached = CachedSession(id: "u1", email: "a@b.com", emailVerified: true)
        let (service, repo, keychain, cache, store) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt"),
            cached: cached
        )
        repo.refreshError = error

        do {
            _ = try await service.performRefresh()
            Issue.record("Expected the failure to throw")
        } catch let caught as APIError {
            #expect(caught == error)
        }

        // Nothing cleared, nothing signed out; the pending attempt survives
        // so the next rotation reuses it.
        #expect(await tokens(keychain) == ("at", "rt"))
        #expect(await TestFactories.snapshotTokens(keychain).attempt != nil)
        #expect(cache.load() == cached)
        #expect(store.state == .signedOut, "no spurious state change on an ambiguous failure")
    }

    @Test("failed successor save serves memory only and keeps recovery intent")
    func successorSaveFailureKeepsIntent() async throws {
        // Seeded mid-replacement: predecessor + attempt already durable, so
        // the send goes out; only the successor save is faulted.
        let (service, repo, keychain, _, _) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(
                accessToken: "at", refreshToken: "rt",
                pendingAttemptId: "attempt-1", pendingPredecessor: "rt"
            )
        )
        repo.attemptAwareServerEnabled = true
        await keychain.setSaveSnapshotError(.storageUnavailable(underlying: "test"), failNextSaves: 1)

        // The in-memory token serves this call, but nothing durable changes.
        let served = try await service.performRefresh()
        #expect(served == "rec-at-1")
        #expect(await tokens(keychain) == ("at", "rt"))
        #expect(await TestFactories.snapshotTokens(keychain).attempt == "attempt-1")

        // The later retry reuses the attempt and converges on the same
        // successor, which now persists completely.
        await keychain.setSaveSnapshotError(nil)
        let recovered = try await service.performRefresh()
        #expect(recovered == "rec-at-1")
        #expect(repo.refreshSends.map(\.attemptId) == ["attempt-1", "attempt-1"])
        #expect(await tokens(keychain) == ("rec-at-1", "rec-rt-1"))
    }

    @Test("intent persistence failure sends no refresh request")
    func intentPersistenceFailureSendsNothing() async throws {
        let (service, repo, keychain, _, _) = makeService(
            initialSnapshot: TestFactories.makeSnapshot(accessToken: "at", refreshToken: "rt")
        )
        await keychain.setSaveSnapshotError(.storageUnavailable(underlying: "test"), failNextSaves: 1)

        do {
            _ = try await service.performRefresh()
            Issue.record("Expected the storage failure to throw")
        } catch let error as APIError {
            #expect(error == .storage(underlying: "keychain storage unavailable: test"))
        }

        #expect(repo.refreshSends.isEmpty, "no request is sent when intent cannot be stored")
        #expect(await tokens(keychain) == ("at", "rt"))
    }

    // MARK: - requestOtp then verifyOtp (cached email)

    @Test("verifyOtp uses the email cached by requestOtp")
    func verifyOtpWithStoredEmail() async throws {
        let (service, repo, keychain, cache, store) = makeService()

        // Simulate: requestOtp was called first, caching the email
        try await service.requestOtp(email: "  User@Example.com ")
        #expect(store.cachedEmail == "user@example.com")

        // verifyOtp with the cached email completes sign-in.
        try await service.verifyOtp(email: "user@example.com", code: "123456")

        #expect(repo.calls == [
            .requestOtp(email: "user@example.com"),
            .verifyOtp(email: "user@example.com", code: "123456"),
        ])
        #expect(await tokens(keychain) == ("at", "rt"))
        #expect(cache.load()?.email == "user@example.com")
        #expect(
            store.state == .signedIn(
                CachedSession(id: "u1", email: "user@example.com", emailVerified: true)
            )
        )
    }
}
