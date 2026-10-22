import Testing
import Foundation
@testable import TimeOfLife

/// Dedicated-Bearer scheme through `APIClient` (account-deletion spec D3):
/// a status credential authenticates its own request, never mints or
/// triggers a session refresh, and wins over any session token.
@Suite("APIClient status bearer", .serialized)
struct APIClientStatusBearerTests {

    let baseURL = URL(string: "http://127.0.0.1:8080")!

    private func makeClient(
        accessToken: String? = "session-token",
        refreshCalls: LockedBox<Int>? = nil
    ) -> APIClient {
        APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            accessTokenProvider: { accessToken },
            refreshHandler: {
                if let box = refreshCalls { box.value += 1 }
                return "new-token"
            }
        )
    }

    final class LockedBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        var value: T
        init(_ value: T) { self.value = value }
        func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
    }

    @Test("customBearer wins over the session token")
    func customBearerWins() async throws {
        defer { URLProtocolStub.clear() }
        var header: String?
        URLProtocolStub.responseHandler = { request in
            header = request.value(forHTTPHeaderField: "Authorization")
            let body = try JSONEncoder().encode(
                AccountStatusResponse(accountID: "u1", state: .active)
            )
            return (body, TestFactories.okResponse(request.url!, status: 200))
        }
        let client = makeClient(accessToken: "session-token")
        _ = try await client.send(
            APIEndpoint(method: .post, path: "/api/v1/auth/account/status", customBearer: "status-cap-1"),
            as: AccountStatusResponse.self
        )
        #expect(header == "Bearer status-cap-1")
    }

    @Test("requiresAuth plus customBearer still sends only the dedicated token")
    func customBearerBeatsRequiresAuth() async throws {
        defer { URLProtocolStub.clear() }
        var header: String?
        URLProtocolStub.responseHandler = { request in
            header = request.value(forHTTPHeaderField: "Authorization")
            let body = try JSONEncoder().encode(
                AccountStatusResponse(accountID: "u1", state: .active)
            )
            return (body, TestFactories.okResponse(request.url!, status: 200))
        }
        let client = makeClient(accessToken: "session-token")
        _ = try await client.send(
            APIEndpoint(method: .post, path: "/x", requiresAuth: true, customBearer: "status-cap-1"),
            as: AccountStatusResponse.self
        )
        #expect(header == "Bearer status-cap-1")
    }

    @Test("a 401 on a status request never triggers the session refresh")
    func status401NeverRefreshes() async throws {
        defer { URLProtocolStub.clear() }
        let calls = LockedBox(0)
        URLProtocolStub.responseHandler = { request in
            (Data(), TestFactories.okResponse(request.url!, status: 401))
        }
        let client = makeClient(refreshCalls: calls)
        do {
            _ = try await client.send(
                APIEndpoint(method: .post, path: "/api/v1/auth/account/status", customBearer: "status-cap-1"),
                as: AccountStatusResponse.self
            )
            Issue.record("expected throw on 401")
        } catch {
        }
        #expect(calls.value == 0)
    }

    @Test("sendRaw surfaces 204 and 202 status codes distinctly")
    func sendRawSurfacesStatuses() async throws {
        for status in [204, 202] {
            defer { URLProtocolStub.clear() }
            URLProtocolStub.responseHandler = { request in
                (Data(), TestFactories.okResponse(request.url!, status: status))
            }
            let client = makeClient()
            let raw = try await client.sendRaw(
                APIEndpoint.value(method: .delete, path: "/api/v1/auth/account", requiresAuth: true)
            )
            #expect(raw.statusCode == status)
        }
    }

    @Test("sendRaw throws the envelope error on non-2xx")
    func sendRawThrowsEnvelope() async throws {
        defer { URLProtocolStub.clear() }
        URLProtocolStub.responseHandler = { request in
            let body = Data("{\"error\":{\"code\":\"unauthorized\",\"message\":\"gone\"}}".utf8)
            return (body, TestFactories.okResponse(request.url!, status: 401))
        }
        let client = makeClient()
        do {
            _ = try await client.sendRaw(
                APIEndpoint.value(method: .delete, path: "/api/v1/auth/account", requiresAuth: true)
            )
            Issue.record("expected throw")
        } catch let error as APIError {
            // A 401 with an envelope surfaces the structured rejection, not
            // a bare unauthorized — either way the caller must not treat it
            // as deletion evidence.
            #expect(error == .authenticationRejected(code: "unauthorized", message: "gone"))
        }
    }
}
