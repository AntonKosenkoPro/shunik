import Testing
import Foundation
@testable import Shunik

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == 0
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

@Suite("APIClient unauthorized handling", .serialized)
struct APIClientUnauthorizedTests {

    let baseURL = URL(string: "http://127.0.0.1:8080")!

    private func makeClient(
        accessTokenProvider: @escaping @Sendable () async -> String? = { nil },
        refreshHandler: (@Sendable () async throws -> String)? = nil
    ) -> APIClient {
        APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            accessTokenProvider: accessTokenProvider,
            refreshHandler: refreshHandler
        )
    }

    @Test("public 401 does not consume the refresh token")
    func publicUnauthorizedDoesNotRefresh() async throws {
        defer { URLProtocolStub.clear() }

        URLProtocolStub.responseHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (Data(), response)
        }
        let refreshCalls = CallCounter()
        let refreshHandler: @Sendable () async throws -> String = {
            refreshCalls.increment()
            return "new"
        }
        let client = makeClient(refreshHandler: refreshHandler)

        do {
            _ = try await client.send(
                APIEndpoint.value(method: .get, path: "/api/v1/auth/me"),
                as: UserDTO.self
            )
            Issue.record("Expected unauthorized error")
        } catch let error as APIError {
            #expect(error == .unauthorized)
        }
        #expect(refreshCalls.isEmpty)
    }

    @Test("refresh errors are preserved for offline recovery")
    func refreshErrorIsPreserved() async throws {
        defer { URLProtocolStub.clear() }

        URLProtocolStub.responseHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (Data(), response)
        }
        let client = makeClient(
            accessTokenProvider: { "expired" },
            refreshHandler: { throw APIError.offline }
        )

        do {
            _ = try await client.send(
                APIEndpoint.value(method: .get, path: "/api/v1/auth/me", requiresAuth: true),
                as: UserDTO.self
            )
            Issue.record("Expected offline error")
        } catch let error as APIError {
            #expect(error == .offline)
        }
    }

    @Test("401 with an envelope surfaces the structured rejection code")
    func structured401SurfacesCode() async throws {
        defer { URLProtocolStub.clear() }

        URLProtocolStub.responseHandler = { request in
            let body = TestFactories.makeErrorResponse(code: "token_reuse", message: "revoked")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (body, response)
        }
        let client = makeClient()

        // A public endpoint: no refresh is owned here, so the rejection
        // surfaces directly instead of routing through the retry path.
        do {
            try await client.sendVoid(
                APIEndpoint(
                    method: .post,
                    path: "/api/v1/auth/otp/request",
                    body: OtpRequestRequest(email: "a@b.com")
                )
            )
            Issue.record("Expected rejection error")
        } catch let error as APIError {
            #expect(error == .authenticationRejected(
                code: "token_reuse", message: "revoked", details: [:]
            ))
            #expect(error.code == "token_reuse")
        }
    }

    @Test("structured 401 still triggers one refresh-and-retry for protected requests")
    func structured401StillRefreshes() async throws {
        defer { URLProtocolStub.clear() }

        let refreshCalls = CallCounter()
        URLProtocolStub.responseHandler = { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old" {
                let body = TestFactories.makeErrorResponse(code: "invalid_refresh", message: "expired")
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 401,
                    httpVersion: "HTTP/1.1", headerFields: nil
                )!
                return (body, response)
            }
            let user = UserDTO(id: "u1", email: "a@b.com", emailVerified: true)
            let data = (try? JSONEncoder().encode(user)) ?? Data()
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (data, response)
        }
        let client = makeClient(
            accessTokenProvider: { "old" },
            refreshHandler: {
                refreshCalls.increment()
                return "new"
            }
        )

        let user = try await client.send(
            APIEndpoint.value(method: .get, path: "/api/v1/auth/me", requiresAuth: true),
            as: UserDTO.self
        )

        #expect(user.id == "u1")
        #expect(refreshCalls.count == 1, "exactly one owned refresh per protected request")
    }

    @Test("failed refresh preserves the structured rejection for the caller")
    func structuredRefreshFailureIsPreserved() async throws {
        defer { URLProtocolStub.clear() }

        URLProtocolStub.responseHandler = { request in
            let body = TestFactories.makeErrorResponse(code: "invalid_refresh", message: "expired")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (body, response)
        }
        let client = makeClient(
            accessTokenProvider: { "expired" },
            refreshHandler: {
                throw APIError.authenticationRejected(code: "token_reuse", message: "revoked")
            }
        )

        do {
            _ = try await client.send(
                APIEndpoint.value(method: .get, path: "/api/v1/auth/me", requiresAuth: true),
                as: UserDTO.self
            )
            Issue.record("Expected rejection error")
        } catch let error as APIError {
            // The refresh outcome surfaces intact — never collapsed into a
            // bare signal the caller would misread as ambiguous.
            #expect(error.code == "token_reuse")
        }
    }
}
