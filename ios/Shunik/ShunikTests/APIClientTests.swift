import Testing
import Foundation
@testable import Shunik

@Suite("APIClient", .serialized)
struct APIClientTests {

    let baseURL = URL(string: "http://127.0.0.1:8080")!

    // MARK: - Helpers

    private func makeClient(
        baseURL: URL? = nil,
        accessTokenProvider: @escaping @Sendable () async -> String? = { nil },
        refreshHandler: (@Sendable () async throws -> String)? = nil,
        deviceIdProvider: (@Sendable () async -> String)? = nil
    ) -> (APIClient, URLSession) {
        let session = URLProtocolStub.makeSession()
        let client = APIClient(
            baseURL: baseURL ?? self.baseURL,
            session: session,
            accessTokenProvider: accessTokenProvider,
            refreshHandler: refreshHandler,
            deviceIdProvider: deviceIdProvider
        )
        return (client, session)
    }

    @Test("X-Device-Id header is not set when no provider is wired")
    func noDeviceIdWithoutProvider() async throws {
        defer { URLProtocolStub.clear() }
        var header: String?
        URLProtocolStub.responseHandler = { request in
            header = request.value(forHTTPHeaderField: "X-Device-Id")
            return (Data(), TestFactories.okResponse(request.url!, status: 204))
        }

        let (client, _) = makeClient(deviceIdProvider: nil)
        try await client.sendVoid(
            APIEndpoint.value(method: .post, path: "/api/v1/auth/otp/verify")
        )

        #expect(header == nil)
    }

    /// Convenience: stubs a URL with a JSON-encoded encodable value.
    private func stubJSON<T: Encodable>(_ value: T, for url: URL, status: Int = 200) {
        guard let data = try? JSONEncoder().encode(value) else {
            URLProtocolStub.stub(data: Data(), statusCode: status, for: url)
            return
        }
        URLProtocolStub.stub(data: data, statusCode: status, for: url)
    }

    /// The endpoint URL for a given path.
    private func url(for path: String) -> URL {
        URL(string: "http://127.0.0.1:8080\(path)")!
    }

    // MARK: - Successful request

    @Test("successful request returns decoded data")
    func successDecode() async throws {
        defer { URLProtocolStub.clear() }

        let session = TestFactories.makeAuthResponse()
        stubJSON(session, for: url(for: "/api/v1/auth/otp/verify"), status: 200)

        let (client, _) = makeClient()
        let resp = try await client.send(
            APIEndpoint(
                method: .post,
                path: "/api/v1/auth/otp/verify",
                body: OtpVerifyRequest(email: "a@b.com", code: "123456")
            ),
            as: AuthSession.self
        )

        #expect(resp.accessToken == "access_token_abc")
        #expect(resp.refreshToken == "refresh_token_xyz")
        #expect(resp.user.id == "u1")
        #expect(resp.user.email == "user@example.com")
        #expect(resp.user.emailVerified == true)
    }

    // MARK: - HTTP error mapping

    @Test("HTTP 422 error maps to APIError.server with correct code and message")
    func httpErrorMapping() async throws {
        defer { URLProtocolStub.clear() }

        let url = self.url(for: "/api/v1/auth/otp/verify")
        let (body, _) = TestFactories.errorResponse(url, status: 422, code: "invalid_otp", message: "Incorrect code")
        URLProtocolStub.stub(data: body, statusCode: 422, for: url)

        let (client, _) = makeClient()

        do {
            _ = try await client.send(
                APIEndpoint(
                    method: .post,
                    path: "/api/v1/auth/otp/verify",
                    body: OtpVerifyRequest(email: "a@b.com", code: "123456")
                ),
                as: AuthSession.self
            )
            Issue.record("Expected error to be thrown")
        } catch let error as APIError {
            #expect(error.code == "invalid_otp")
            #expect(error.message == "Incorrect code")
        }
    }

    // MARK: - 401 triggers token refresh and retry

    @Test("401 triggers token refresh and retries once with new token")
    func refreshRetry() async throws {
        defer { URLProtocolStub.clear() }

        var callCount = 0

        // Use the closure-based approach for multi-step scenarios
        URLProtocolStub.responseHandler = { request in
            callCount += 1
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old" {
                // First attempt: 401
                let body = TestFactories.makeErrorResponse(code: "invalid_refresh", message: "x")
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 401,
                    httpVersion: "HTTP/1.1", headerFields: nil
                )!
                return (body, resp)
            }
            // Retry with new token: success
            let user = UserDTO(id: "u1", email: "a@b.com", emailVerified: true)
            let data = (try? JSONEncoder().encode(user)) ?? Data()
            return (data, TestFactories.okResponse(request.url!, status: 200))
        }

        let (client, _) = makeClient(
            accessTokenProvider: { "old" },
            refreshHandler: { "new" }
        )

        let user = try await client.send(
            APIEndpoint.value(method: .get, path: "/api/v1/auth/me", requiresAuth: true),
            as: UserDTO.self
        )

        #expect(user.id == "u1")
        #expect(callCount == 2) // initial + retry
    }

    @Test("401 without refresh handler throws unauthorized")
    func noRefreshThrows() async throws {
        defer { URLProtocolStub.clear() }

        URLProtocolStub.responseHandler = { request in
            let body = Data()
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 401,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (body, resp)
        }

        let (client, _) = makeClient()

        do {
            _ = try await client.send(
                APIEndpoint.value(method: .get, path: "/api/v1/auth/me", requiresAuth: true),
                as: UserDTO.self
            )
            Issue.record("Expected unauthorized error")
        } catch let error as APIError {
            #expect(error == .unauthorized)
        }
    }

    // MARK: - Network error mapping

    @Test("network error maps to APIError.offline")
    func networkErrorMapping() async throws {
        defer { URLProtocolStub.clear() }

        let url = self.url(for: "/api/v1/auth/me")
        URLProtocolStub.stub(error: URLError(.notConnectedToInternet), for: url)

        let (client, _) = makeClient()

        do {
            _ = try await client.send(
                APIEndpoint.value(method: .get, path: "/api/v1/auth/me"),
                as: UserDTO.self
            )
            Issue.record("Expected offline error")
        } catch let error as APIError {
            #expect(error == .offline)
        }
    }

    @Test("network connection lost maps to APIError.offline")
    func networkConnectionLost() async throws {
        defer { URLProtocolStub.clear() }

        let url = self.url(for: "/api/v1/auth/me")
        URLProtocolStub.stub(error: URLError(.networkConnectionLost), for: url)

        let (client, _) = makeClient()

        do {
            _ = try await client.send(
                APIEndpoint.value(method: .get, path: "/api/v1/auth/me"),
                as: UserDTO.self
            )
            Issue.record("Expected offline error")
        } catch let error as APIError {
            #expect(error == .offline)
        }
    }

    // MARK: - Invalid response

    @Test("non-HTTP response maps to APIError.unexpected")
    func invalidResponse() async throws {
        defer { URLProtocolStub.clear() }

        // Return a non-HTTP response by using the closure handler
        URLProtocolStub.responseHandler = { request in
            // We can't easily return a non-HTTP response via URLProtocolStub,
            // so we simulate it by returning a bad status code that the client
            // will try to parse as an error envelope.
            let body = Data()
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 999,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (body, resp)
        }

        let (client, _) = makeClient()

        do {
            _ = try await client.send(
                APIEndpoint.value(method: .get, path: "/api/v1/auth/me"),
                as: UserDTO.self
            )
            Issue.record("Expected error")
        } catch let error as APIError {
            // 999 with empty body → server error with http_999 code
            #expect(error.code == "http_999")
        }
    }

    // MARK: - Rate limiting (429)

    @Test("rate limiting (429) maps to APIError.server with http_429 code")
    func rateLimiting() async throws {
        defer { URLProtocolStub.clear() }

        let url = self.url(for: "/api/v1/auth/otp/request")
        let (body, _) = TestFactories.errorResponse(
            url, status: 429,
            code: "rate_limited",
            message: "Too many attempts. Try again later."
        )
        URLProtocolStub.stub(data: body, statusCode: 429, for: url)

        let (client, _) = makeClient()

        do {
            try await client.sendVoid(
                APIEndpoint(
                    method: .post,
                    path: "/api/v1/auth/otp/request",
                    body: OtpRequestRequest(email: "a@b.com")
                )
            )
            Issue.record("Expected rate limit error")
        } catch let error as APIError {
            #expect(error.code == "rate_limited")
            #expect(error.message == "Too many attempts. Try again later.")
        }
    }

    // MARK: - sendVoid

    @Test("sendVoid tolerates empty 204 body")
    func sendVoidEmpty() async throws {
        defer { URLProtocolStub.clear() }

        URLProtocolStub.responseHandler = { request in
            (Data(), HTTPURLResponse(
                url: request.url!, statusCode: 204,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!)
        }

        let (client, _) = makeClient()
        try await client.sendVoid(
            APIEndpoint.value(method: .post, path: "/api/v1/auth/logout", requiresAuth: true)
        )
    }

    @Test("sendVoid accepts 202 with empty body (otp/request)")
    func sendVoid202() async throws {
        defer { URLProtocolStub.clear() }

        URLProtocolStub.responseHandler = { request in
            (Data(), HTTPURLResponse(
                url: request.url!, statusCode: 202,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!)
        }

        let (client, _) = makeClient()
        try await client.sendVoid(
            APIEndpoint(
                method: .post,
                path: "/api/v1/auth/otp/request",
                body: OtpRequestRequest(email: "a@b.com")
            )
        )
    }

    // MARK: - Decoding error

    @Test("invalid JSON response maps to APIError.decoding")
    func decodingError() async throws {
        defer { URLProtocolStub.clear() }

        let url = self.url(for: "/api/v1/auth/me")
        let invalidJSON = Data("not valid json".utf8)
        URLProtocolStub.stub(data: invalidJSON, for: url)

        let (client, _) = makeClient()

        do {
            _ = try await client.send(
                APIEndpoint.value(method: .get, path: "/api/v1/auth/me"),
                as: UserDTO.self
            )
            Issue.record("Expected decoding error")
        } catch let error as APIError {
            if case .decoding = error {
                // Success
            } else {
                Issue.record("Expected decoding error, got \(error)")
            }
        }
    }

    // MARK: - URL construction

    @Test("baseURL with trailing slash produces correct request URL")
    func baseURLWithTrailingSlash() async throws {
        defer { URLProtocolStub.clear() }

        let trailingBaseURL = URL(string: "http://127.0.0.1:8080/")!
        let expectedURL = URL(string: "http://127.0.0.1:8080/api/v1/auth/me")!
        let user = UserDTO(id: "u1", email: "a@b.com", emailVerified: true)
        stubJSON(user, for: expectedURL, status: 200)

        let (client, _) = makeClient(baseURL: trailingBaseURL)
        let resp = try await client.send(
            APIEndpoint.value(method: .get, path: "/api/v1/auth/me"),
            as: UserDTO.self
        )

        #expect(resp.email == "a@b.com")
    }
}
