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

    func appleSignIn(identityToken: String, authorizationCode: String? = nil) async throws -> AuthSession {
        try await client.send(
            APIEndpoint(method: .post, path: "\(basePath)/auth/apple",
                        body: AppleSignInRequest(identityToken: identityToken, authorizationCode: authorizationCode)),
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

    func me() async throws -> MeResponse {
        try await client.send(
            APIEndpoint.value(method: .get, path: "\(basePath)/auth/me", requiresAuth: true),
            as: MeResponse.self
        )
    }

    func deleteAccount() async throws -> AccountDeletionOutcome {
        let (data, statusCode) = try await client.sendRaw(
            APIEndpoint.value(method: .delete, path: "\(basePath)/auth/account", requiresAuth: true)
        )
        switch statusCode {
        case 204:
            return .completed
        case 202:
            // 202 without an explicit `account_deleted: true` body is NOT
            // deletion evidence — fail loudly instead of announcing success.
            let decoded: AccountDeletionResponse
            do {
                decoded = try JSONDecoder().decode(AccountDeletionResponse.self, from: data)
            } catch {
                throw APIError.decoding(underlying: String(describing: error))
            }
            guard decoded.accountDeleted else {
                throw APIError.decoding(underlying: "DELETE /auth/account 202 without account_deleted=true")
            }
            return decoded.appleRevocationPending ? .pendingAppleRevocation : .completed
        default:
            throw APIError.unexpected
        }
    }

    func fetchAccountStatus(statusCredential: String) async throws -> AccountStatusResponse {
        try await client.send(
            APIEndpoint(method: .post, path: "\(basePath)/auth/account/status",
                        customBearer: statusCredential),
            as: AccountStatusResponse.self
        )
    }

    func acquireAppleDeletionCredential(identityToken: String, authorizationCode: String?) async throws {
        try await client.sendVoid(
            APIEndpoint(method: .post, path: "\(basePath)/auth/apple/deletion-credential",
                        body: AppleDeletionCredentialRequest(
                            identityToken: identityToken,
                            authorizationCode: authorizationCode
                        ),
                        requiresAuth: true)
        )
    }
}
