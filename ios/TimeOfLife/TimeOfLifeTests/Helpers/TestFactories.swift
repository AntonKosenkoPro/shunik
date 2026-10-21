import Foundation
import Testing
@testable import TimeOfLife

/// Helpers for building decoded payloads and HTTP responses in tests.
enum TestFactories {

    // MARK: - Model factories

    /// Creates a `UserDTO` with sensible defaults.
    static func makeUser(
        id: String = "u1",
        email: String = "user@example.com",
        emailVerified: Bool = true
    ) -> UserDTO {
        UserDTO(id: id, email: email, emailVerified: emailVerified)
    }

    /// Creates an `AuthSession` with sensible defaults.
    static func makeAuthResponse(
        accessToken: String = "access_token_abc",
        refreshToken: String = "refresh_token_xyz",
        user: UserDTO? = nil
    ) -> AuthSession {
        AuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            user: user ?? makeUser()
        )
    }

    /// Creates a durable `CredentialSnapshot` with sensible defaults.
    static func makeSnapshot(
        accessToken: String = "at",
        refreshToken: String = "rt",
        accountId: String = "u1",
        deviceId: String? = "device-1",
        pendingAttemptId: String? = nil,
        pendingPredecessor: String? = nil
    ) -> CredentialSnapshot {
        CredentialSnapshot(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountId: accountId,
            deviceId: deviceId,
            pendingAttemptId: pendingAttemptId,
            pendingPredecessor: pendingPredecessor
        )
    }

    /// Reads the durable token pair (plus pending attempt) from a keychain.
    /// A storage failure is recorded as a test issue: callers must never
    /// mistake "unreadable" for "cleared", or a faulted load would falsely
    /// satisfy sign-out assertions.
    static func snapshotTokens(_ keychain: InMemoryKeychainStore) async -> (
        access: String?, refresh: String?, attempt: String?
    ) {
        guard case .success(let snapshot) = await keychain.loadSnapshot() else {
            Issue.record("snapshotTokens: keychain load failed — nils here mean 'unreadable', not 'cleared'")
            return (nil, nil, nil)
        }
        return (snapshot?.accessToken, snapshot?.refreshToken, snapshot?.pendingAttemptId)
    }

    /// Waits until the fake records a refresh send. Throws on timeout so the
    /// caller aborts deterministically instead of mutating state while the
    /// refresh never went in flight (which would misattribute later
    /// failures to the behavior under test instead of request ordering).
    static func waitForRefreshSend(_ repo: FakeAuthRepository) async throws {
        var polls = 0
        while repo.refreshSends.isEmpty && polls < 500 {
            try await Task.sleep(nanoseconds: 1_000_000)
            polls += 1
        }
        if repo.refreshSends.isEmpty {
            Issue.record("refresh send not recorded within 500ms — the refresh was not in flight when state was mutated")
            throw TestTimeoutError.waitForRefreshSend
        }
    }

    /// Test-only timeout failures. Thrown (never returned) so a missed
    /// rendezvous aborts the test instead of silently continuing.
    enum TestTimeoutError: Error {
        case waitForRefreshSend
        case waitForSaveGate
    }

    /// Waits until the fake records a save-gate entry, throwing on timeout
    /// so the interleaving point is proven — never sleep-and-hope.
    static func waitForSaveGate(_ keychain: InMemoryKeychainStore) async throws {
        var polls = 0
        while await !keychain.saveGateEntered && polls < 500 {
            try await Task.sleep(nanoseconds: 1_000_000)
            polls += 1
        }
        if await !keychain.saveGateEntered {
            Issue.record("save gate never entered — logout did not land mid-save")
            throw TestTimeoutError.waitForSaveGate
        }
    }

    /// Waits until the fake records the expected number of refresh sends,
    /// throwing on timeout. Distinguishes "joined the stale task" (count
    /// stays) from "started a fresh attempt" (count grows).
    static func waitForRefreshSends(_ repo: FakeAuthRepository, count: Int) async throws {
        var polls = 0
        while repo.refreshSends.count < count && polls < 500 {
            try await Task.sleep(nanoseconds: 1_000_000)
            polls += 1
        }
        if repo.refreshSends.count < count {
            Issue.record("expected \(count) refresh sends — a caller joined a stale task instead of starting fresh")
            throw TestTimeoutError.waitForRefreshSend
        }
    }

    /// Creates a JSON-encoded error envelope matching the server contract.
    static func makeErrorResponse(
        code: String,
        message: String,
        details: [String: Any] = [:]
    ) -> Data {
        var payload: [String: Any] = ["code": code, "message": message]
        if !details.isEmpty {
            payload["details"] = details
        }
        let envelope: [String: Any] = ["error": payload]
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
    }

    // MARK: - HTTP response factories

    /// Creates a 200 `HTTPURLResponse` for the given URL.
    static func okResponse(
        _ url: URL,
        status: Int = 200
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    /// Creates an error `HTTPURLResponse` with a JSON error envelope body.
    static func errorResponse(
        _ url: URL,
        status: Int,
        code: String,
        message: String,
        details: [String: Any] = [:]
    ) -> (Data, HTTPURLResponse) {
        let body = makeErrorResponse(code: code, message: message, details: details)
        let resp = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, resp)
    }

    // MARK: - Service factories

    /// Builds a wired-up `AuthService` with in-memory stores for view-model tests.
    @MainActor
    static func makeService(
        repo: FakeAuthRepository = FakeAuthRepository()
    ) -> (AuthService, FakeAuthRepository, Connectivity, SessionStore) {
        let keychain = InMemoryKeychainStore()
        let cache = SessionCache(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = SessionStore()
        let service = AuthService(
            repository: repo,
            keychain: keychain,
            cache: cache,
            sessionStore: store
        )
        return (service, repo, Connectivity(), store)
    }
}
