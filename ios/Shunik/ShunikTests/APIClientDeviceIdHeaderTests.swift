import Testing
import Foundation
@testable import Shunik

/// `X-Device-Id` plumbing through `APIClient.makeRequest` (device-sessions
/// spec): every session-carrying auth request must carry the header; the
/// backend 400s without it, so the missing-header path never triggers.
@Suite("APIClient device id header", .serialized)
struct APIClientDeviceIdHeaderTests {

    let baseURL = URL(string: "http://127.0.0.1:8080")!

    /// The session-carrying auth routes (device-sessions spec). `otp/request`
    /// is deliberately absent — the backend does not require the header there.
    private static let authPaths: [(path: String, requiresAuth: Bool)] = [
        ("/api/v1/auth/otp/verify", false),
        ("/api/v1/auth/apple", false),
        ("/api/v1/auth/refresh", false),
        ("/api/v1/auth/logout", true),
    ]

    /// Sends one request and captures the `X-Device-Id` header it carried.
    private func captureDeviceIdHeader(
        path: String,
        requiresAuth: Bool = false,
        deviceIdProvider: @escaping @Sendable () async -> String
    ) async throws -> String? {
        defer { URLProtocolStub.clear() }
        var header: String?
        URLProtocolStub.responseHandler = { request in
            header = request.value(forHTTPHeaderField: "X-Device-Id")
            return (Data(), TestFactories.okResponse(request.url!, status: 204))
        }
        let client = APIClient(
            baseURL: baseURL,
            session: URLProtocolStub.makeSession(),
            deviceIdProvider: deviceIdProvider
        )
        try await client.sendVoid(
            APIEndpoint.value(method: .post, path: path, requiresAuth: requiresAuth)
        )
        return header
    }

    @Test("X-Device-Id is sent on every session-carrying auth request", arguments: authPaths)
    func deviceIdHeaderOnAuthRequests(argument: (path: String, requiresAuth: Bool)) async throws {
        let header = try await captureDeviceIdHeader(
            path: argument.path,
            requiresAuth: argument.requiresAuth
        ) {
            "11111111-2222-3333-4444-555555555555"
        }
        #expect(header == "11111111-2222-3333-4444-555555555555")
    }

    @Test("X-Device-Id is a valid UUID read per request from the provider")
    func deviceIdHeaderIsUUID() async throws {
        let header = try await captureDeviceIdHeader(
            path: "/api/v1/auth/refresh"
        ) {
            UUID().uuidString
        }
        #expect(UUID(uuidString: header ?? "") != nil)
    }
}
