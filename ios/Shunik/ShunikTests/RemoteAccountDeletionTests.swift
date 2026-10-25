import Testing
import Foundation
@testable import Shunik

/// Wire contract for the account-deletion endpoints (account-deletion spec
/// 2.5 + D4): `DELETE /auth/account` distinguishes 204 (complete) from 202
/// with explicit `account_deleted: true` (pending Apple revocation), and
/// NEVER treats generic failures as deletion. Status and Apple credential
/// endpoints carry their dedicated schemes.
@Suite("Remote account deletion")
struct RemoteAccountDeletionTests {

    private func makeRepo() -> (RemoteAuthRepository, MockAPIClient) {
        let mock = MockAPIClient()
        return (RemoteAuthRepository(client: mock), mock)
    }

    private func deletion202Body(pending: Bool) throws -> Data {
        try JSONEncoder().encode(
            AccountDeletionResponse(accountDeleted: true, appleRevocationPending: pending)
        )
    }

    // MARK: - DELETE /auth/account

    @Test("DELETE targets the authenticated account with auth + no body claim")
    func deleteAccountEndpoint() async throws {
        let (repo, mock) = makeRepo()
        mock.sendRawHandler = { _ in (Data(), 204) }

        let outcome = try await repo.deleteAccount()

        #expect(outcome == .completed)
        let request = try #require(mock.received.first)
        #expect(request.method == .delete)
        #expect(request.path == "/api/v1/auth/account")
        #expect(request.requiresAuth == true)
    }

    @Test("204 means completed purge with revocation complete or N/A")
    func delete204Completed() async throws {
        let (repo, mock) = makeRepo()
        mock.sendRawHandler = { _ in (Data(), 204) }
        #expect(try await repo.deleteAccount() == .completed)
    }

    @Test("202 with account_deleted true and pending true means pending revocation")
    func delete202Pending() async throws {
        let (repo, mock) = makeRepo()
        mock.sendRawHandler = { _ in (try deletion202Body(pending: true), 202) }
        #expect(try await repo.deleteAccount() == .pendingAppleRevocation)
    }

    @Test("202 with account_deleted true and pending false means completed")
    func delete202NoPendingMeansCompleted() async throws {
        let (repo, mock) = makeRepo()
        mock.sendRawHandler = { _ in (try deletion202Body(pending: false), 202) }
        #expect(try await repo.deleteAccount() == .completed)
    }

    @Test("202 without account_deleted true throws instead of claiming deletion")
    func delete202WithoutFlagThrows() async throws {
        let (repo, mock) = makeRepo()
        let body = try JSONEncoder().encode(
            AccountDeletionResponse(accountDeleted: false, appleRevocationPending: true)
        )
        mock.sendRawHandler = { _ in (body, 202) }
        do {
            _ = try await repo.deleteAccount()
            Issue.record("202 without account_deleted=true must throw")
        } catch let error as APIError {
            if case .decoding = error {
            } else {
                Issue.record("expected decoding error, got \(error)")
            }
        }
    }

    @Test("202 with a malformed body throws instead of claiming deletion")
    func delete202MalformedThrows() async throws {
        let (repo, mock) = makeRepo()
        mock.sendRawHandler = { _ in (Data("not json".utf8), 202) }
        do {
            _ = try await repo.deleteAccount()
            Issue.record("malformed 202 must throw")
        } catch let error as APIError {
            if case .decoding = error {
            } else {
                Issue.record("expected decoding error, got \(error)")
            }
        }
    }

    @Test("DELETE propagates offline and server errors without an outcome")
    func deletePropagatesFailures() async throws {
        for failure: Error in [
            APIError.offline,
            APIError.server(code: "http_500", message: "boom"),
            APIError.unauthorized,
            APIError.authenticationRejected(code: "invalid_refresh", message: "gone"),
        ] {
            let (repo, mock) = makeRepo()
            mock.throwError = failure
            do {
                _ = try await repo.deleteAccount()
                Issue.record("expected throw for \(failure)")
            } catch {
            }
        }
    }

    // MARK: - POST /auth/account/status

    @Test("status uses the dedicated Bearer scheme, never the session token")
    func statusEndpointScheme() async throws {
        let (repo, mock) = makeRepo()
        mock.sendHandler = { _, _ in
            AccountStatusResponse(accountID: "u1", state: .active)
        }

        let verdict = try await repo.fetchAccountStatus(statusCredential: "status-cap-1")

        #expect(verdict.accountID == "u1")
        #expect(verdict.state == .active)
        let request = try #require(mock.received.first)
        #expect(request.method == .post)
        #expect(request.path == "/api/v1/auth/account/status")
        #expect(request.requiresAuth == false)
        #expect(request.customBearer == "status-cap-1")
    }

    @Test("deleted verdict decodes")
    func statusDeletedDecodes() async throws {
        let (repo, mock) = makeRepo()
        mock.sendHandler = { _, _ in
            AccountStatusResponse(accountID: "u9", state: .deleted)
        }
        let verdict = try await repo.fetchAccountStatus(statusCredential: "status-cap-9")
        #expect(verdict == AccountStatusResponse(accountID: "u9", state: .deleted))
    }

    // MARK: - POST /auth/apple/deletion-credential

    @Test("deletion-credential sends identity token plus code under auth")
    func deletionCredentialEndpoint() async throws {
        let (repo, mock) = makeRepo()
        mock.sendVoidHandler = { _ in }

        try await repo.acquireAppleDeletionCredential(identityToken: "id-token", authorizationCode: "code-1")

        let request = try #require(mock.received.first)
        #expect(request.method == .post)
        #expect(request.path == "/api/v1/auth/apple/deletion-credential")
        #expect(request.requiresAuth == true)
        let body = try #require(request.body)
        let decoded = try JSONDecoder().decode(AppleDeletionCredentialRequest.self, from: body)
        #expect(decoded == AppleDeletionCredentialRequest(identityToken: "id-token", authorizationCode: "code-1"))
    }

    @Test("deletion-credential propagates rejection without side effects")
    func deletionCredentialRejects() async throws {
        let (repo, mock) = makeRepo()
        mock.sendVoidHandler = { _ in
            throw APIError.server(code: "apple_subject_mismatch", message: "different identity")
        }
        do {
            try await repo.acquireAppleDeletionCredential(identityToken: "id-token", authorizationCode: nil)
            Issue.record("expected throw")
        } catch let error as APIError {
            #expect(error.code == "apple_subject_mismatch")
        }
    }

    // MARK: - Apple sign-in authorization code

    @Test("apple sign-in forwards the authorization code when present")
    func appleSignInForwardsCode() async throws {
        let (repo, mock) = makeRepo()
        mock.sendHandler = { _, _ in TestFactories.makeAuthResponse() }

        _ = try await repo.appleSignIn(identityToken: "id-token", authorizationCode: "code-9")

        let request = try #require(mock.received.first)
        #expect(request.path == "/api/v1/auth/apple")
        let body = try #require(request.body)
        let decoded = try JSONDecoder().decode(AppleSignInRequest.self, from: body)
        #expect(decoded == AppleSignInRequest(identityToken: "id-token", authorizationCode: "code-9"))
    }

    @Test("apple sign-in omits the code for rollout-compat clients")
    func appleSignInOmitsNilCode() async throws {
        let (repo, mock) = makeRepo()
        mock.sendHandler = { _, _ in TestFactories.makeAuthResponse() }

        _ = try await repo.appleSignIn(identityToken: "id-token", authorizationCode: nil)

        let request = try #require(mock.received.first)
        let body = try #require(request.body)
        let decoded = try JSONDecoder().decode(AppleSignInRequest.self, from: body)
        #expect(decoded.authorizationCode == nil)
    }

    // MARK: - me carries status evidence

    @Test("me decodes the status credential and expiry")
    func meDecodesStatusEvidence() async throws {
        let (repo, mock) = makeRepo()
        mock.sendHandler = { _, _ in
            MeResponse(
                user: TestFactories.makeUser(),
                accountStatusCredential: "status-cap-1",
                accountStatusExpiresAt: "2099-01-01T00:00:00Z"
            )
        }
        let response = try await repo.me()
        #expect(response.accountStatusCredential == "status-cap-1")
        #expect(response.accountStatusExpiresAt == "2099-01-01T00:00:00Z")
    }

    @Test("me tolerates relays without status fields")
    func meToleratesMissingStatus() async throws {
        let (repo, mock) = makeRepo()
        mock.sendHandler = { _, _ in MeResponse(user: TestFactories.makeUser()) }
        let response = try await repo.me()
        #expect(response.accountStatusCredential == nil)
        #expect(response.accountStatusExpiresAt == nil)
    }
}
