import Foundation

/// `AuthRepository` backed by an `APIClient`. Maps domain calls onto the
/// shared contract's endpoints; does not own tokens — that's `AuthService`.
final class RemoteAuthRepository: AuthRepository {
    private let client: APISending
    private let basePath = "/api/v1"

    init(client: APISending) {
        self.client = client
    }

    func requestOtp(email: String) async throws {
        try await client.sendVoid(
            APIEndpoint(method: .post, path: "\(basePath)/auth/otp/request",
                        body: OtpRequestRequest(email: email))
        )
    }

    func verifyOtp(email: String, code: String) async throws -> AuthSession {
        try await client.send(
            APIEndpoint(method: .post, path: "\(basePath)/auth/otp/verify",
                        body: OtpVerifyRequest(email: email, code: code)),
            as: AuthSession.self
        )
    }

    func appleSignIn(identityToken: String) async throws -> AuthSession {
        try await client.send(
            APIEndpoint(method: .post, path: "\(basePath)/auth/apple",
                        body: AppleSignInRequest(identityToken: identityToken)),
            as: AuthSession.self
        )
    }

    func refresh(refreshToken: String, attemptId: String) async throws -> AuthSession {
        try await client.send(
            APIEndpoint(method: .post, path: "\(basePath)/auth/refresh",
                        body: RefreshRequest(refreshToken: refreshToken, refreshAttemptId: attemptId)),
            as: AuthSession.self
        )
    }

    func logout() async throws {
        try await client.sendVoid(
            APIEndpoint.value(method: .post, path: "\(basePath)/auth/logout", requiresAuth: true)
        )
    }

    func me() async throws -> UserDTO {
        let response = try await client.send(
            APIEndpoint.value(method: .get, path: "\(basePath)/auth/me", requiresAuth: true),
            as: MeResponse.self
        )
        return response.user
    }
}

struct MeResponse: Decodable, Sendable {
    let user: UserDTO
}
