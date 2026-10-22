import Testing
import Foundation
@testable import TimeOfLife

@Suite("RemoteAuthRepository")
struct RemoteAuthRepositoryTests {

    private func makeRepo() -> (RemoteAuthRepository, MockAPIClient) {
        let mock = MockAPIClient()
        let repo = RemoteAuthRepository(client: mock)
        return (repo, mock)
    }

    // MARK: - requestOTP

    @Test("requestOTP calls POST /auth/otp/request with correct body")
    func requestOtpEndpoint() async throws {
        let (repo, mock) = makeRepo()
        mock.sendVoidHandler = { _ in }

        try await repo.requestOtp(email: "a@b.com")

        let r = try #require(mock.received.first)
        #expect(r.method == .post)
        #expect(r.path == "/api/v1/auth/otp/request")
        #expect(r.requiresAuth == false)

        let body = try #require(r.body)
        let decoded = try JSONDecoder().decode(OtpRequestRequest.self, from: body)
        #expect(decoded.email == "a@b.com")
    }

    @Test("requestOTP handles success (202) without throwing")
    func requestOtpSuccess() async throws {
        let (repo, mock) = makeRepo()
        mock.sendVoidHandler = { _ in }

        // Should not throw
        try await repo.requestOtp(email: "a@b.com")
        #expect(mock.sendVoidCallCount == 1)
    }

    @Test("requestOTP propagates network error")
    func requestOtpNetworkError() async throws {
        let (repo, mock) = makeRepo()
        mock.sendVoidHandler = { _ in throw APIError.offline }

        do {
            try await repo.requestOtp(email: "a@b.com")
            Issue.record("Expected error to be thrown")
        } catch let error as APIError {
            #expect(error == .offline)
        }
    }

    // MARK: - verifyOTP

    @Test("verifyOTP calls POST /auth/otp/verify with correct body")
    func verifyOtpEndpoint() async throws {
        let (repo, mock) = makeRepo()
        mock.sendHandler = { _, _ in
            TestFactories.makeAuthResponse()
        }

        _ = try await repo.verifyOtp(email: "a@b.com", code: "123456")

        let r = try #require(mock.received.first)
        #expect(r.method == .post)
        #expect(r.path == "/api/v1/auth/otp/verify")
        #expect(r.requiresAuth == false)

        let body = try #require(r.body)
        let decoded = try JSONDecoder().decode(OtpVerifyRequest.self, from: body)
        #expect(decoded.email == "a@b.com")
        #expect(decoded.code == "123456")
    }

    @Test("verifyOTP returns tokens and user on success")
    func verifyOtpSuccess() async throws {
        let (repo, mock) = makeRepo()
        let expectedSession = TestFactories.makeAuthResponse(
            accessToken: "at1",
            refreshToken: "rt1",
            user: TestFactories.makeUser(id: "u42", email: "test@example.com")
        )
        mock.sendHandler = { _, _ in expectedSession }

        let session = try await repo.verifyOtp(email: "test@example.com", code: "123456")

        #expect(session.accessToken == "at1")
        #expect(session.refreshToken == "rt1")
        #expect(session.user.id == "u42")
        #expect(session.user.email == "test@example.com")
    }

    @Test("verifyOTP maps error responses correctly")
    func verifyOtpErrorMapping() async throws {
        let (repo, mock) = makeRepo()
        mock.sendHandler = { _, _ in
            throw APIError.server(code: "invalid_otp", message: "Incorrect code. Try again.")
        }

        do {
            _ = try await repo.verifyOtp(email: "a@b.com", code: "123456")
            Issue.record("Expected error to be thrown")
        } catch let error as APIError {
            #expect(error.code == "invalid_otp")
            #expect(error.message == "Incorrect code. Try again.")
        }
    }

    // MARK: - refreshToken

    @Test("refreshToken calls POST /auth/refresh with token and attempt id")
    func refreshEndpoint() async throws {
        let (repo, mock) = makeRepo()
        mock.sendHandler = { _, _ in
            TestFactories.makeAuthResponse(accessToken: "at2", refreshToken: "rt2")
        }

        _ = try await repo.refresh(refreshToken: "rt1", attemptId: "attempt-1")

        let r = try #require(mock.received.first)
        #expect(r.path == "/api/v1/auth/refresh")

        let body = try #require(r.body)
        let decoded = try JSONDecoder().decode(RefreshRequest.self, from: body)
        #expect(decoded.refreshToken == "rt1")
        #expect(decoded.refreshAttemptId == "attempt-1", "the attempt id is always sent")
    }

    @Test("refreshToken returns new token pair on success")
    func refreshTokenSuccess() async throws {
        let (repo, mock) = makeRepo()
        let expectedSession = TestFactories.makeAuthResponse(
            accessToken: "new_access",
            refreshToken: "new_refresh"
        )
        mock.sendHandler = { _, _ in expectedSession }

        let session = try await repo.refresh(refreshToken: "old_refresh", attemptId: "attempt-9")

        #expect(session.accessToken == "new_access")
        #expect(session.refreshToken == "new_refresh")
    }

    // MARK: - logout

    @Test("logout calls POST /auth/logout with auth")
    func logoutEndpoint() async throws {
        let (repo, mock) = makeRepo()
        mock.sendVoidHandler = { _ in }

        try await repo.logout()

        let r = try #require(mock.received.first)
        #expect(r.method == .post)
        #expect(r.path == "/api/v1/auth/logout")
        #expect(r.requiresAuth == true)
    }

    // MARK: - me (getUser)

    @Test("getUser calls GET /auth/me with auth and returns user")
    func meEndpoint() async throws {
        let (repo, mock) = makeRepo()
        let expectedUser = TestFactories.makeUser(id: "u1", email: "user@example.com")
        mock.sendHandler = { _, _ in MeResponse(user: expectedUser) }

        let response = try await repo.me()
        let user = response.user

        #expect(user.id == "u1")
        #expect(user.email == "user@example.com")
        #expect(user.emailVerified == true)

        let r = try #require(mock.received.first)
        #expect(r.method == .get)
        #expect(r.path == "/api/v1/auth/me")
        #expect(r.requiresAuth == true)
    }
}
