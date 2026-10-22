import Foundation
@testable import TimeOfLife

/// Records calls and returns canned results / errors. Used to drive
/// `AuthService` and view models without a network.
///
/// Thread-safe via `NSLock`.
final class FakeAuthRepository: AuthRepository, @unchecked Sendable {

    /// Recorded call types for verification.
    enum Call: Equatable {
        case requestOtp(email: String)
        case verifyOtp(email: String, code: String)
        case appleSignIn(identityToken: String, authorizationCode: String?)
        case refresh(refreshToken: String, attemptId: String)
        case logout
        case me
        case deleteAccount
        case fetchAccountStatus
        case acquireAppleDeletionCredential(identityToken: String, authorizationCode: String?)
    }

    // MARK: - State

    private let lock = NSLock()
    private var _calls: [Call] = []

    /// All recorded calls, in order.
    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    /// Recorded refresh sends as `(predecessor, attemptId)` pairs.
    var refreshSends: [(refreshToken: String, attemptId: String)] {
        calls.compactMap {
            if case let .refresh(refreshToken, attemptId) = $0 {
                return (refreshToken, attemptId)
            }
            return nil
        }
    }

    // MARK: - Canned results

    /// Result returned by `verifyOtp` when no error is set.
    var otpVerifyResult = AuthSession(
        accessToken: "at",
        refreshToken: "rt",
        user: UserDTO(id: "u1", email: "a@b.com", emailVerified: true)
    )

    /// Result returned by `appleSignIn` when no error is set.
    var appleSignInResult = AuthSession(
        accessToken: "at-apple",
        refreshToken: "rt-apple",
        user: UserDTO(id: "u-apple", email: "apple@privaterelay.appleid.com", emailVerified: true)
    )

    /// Result returned by `refresh` when no error is set.
    var refreshResult = AuthSession(
        accessToken: "at2",
        refreshToken: "rt2",
        user: UserDTO(id: "u1", email: "a@b.com", emailVerified: true)
    )

    /// Result returned by `me` when no error is set.
    var meResult = MeResponse(
        user: UserDTO(id: "u1", email: "a@b.com", emailVerified: true)
    )

    /// Result returned by `deleteAccount` when no error is set.
    var deleteAccountResult: AccountDeletionOutcome = .completed
    /// Result returned by `fetchAccountStatus` when no error is set.
    var accountStatusResult = AccountStatusResponse(accountID: "u1", state: .active)

    // MARK: - Per-method errors

    /// If set, `requestOtp` throws this error.
    var otpRequestError: Error?
    /// If set, `verifyOtp` throws this error.
    var otpVerifyError: Error?
    /// If set, `appleSignIn` throws this error.
    var appleSignInError: Error?
    /// If set, `refresh` throws this error.
    var refreshError: Error?
    /// If set, `logout` throws this error.
    var logoutError: Error?
    /// If set, `me` throws this error.
    var meError: Error?
    /// If set, `deleteAccount` throws this error.
    var deleteAccountError: Error?
    /// If set, `fetchAccountStatus` throws this error.
    var accountStatusError: Error?
    /// If set, `acquireAppleDeletionCredential` throws this error.
    var deletionCredentialError: Error?
    /// Hook run inside `me()` before it returns/throws. Tests use it to
    /// simulate a transparent refresh having landed (rotating the Keychain
    /// snapshot) before a retry-401 surfaces.
    var meHook: (() async -> Void)?
    /// Injected latency for `me`: the restoring-splash tests hold the launch
    /// gate mid-restore to assert the splash stays up until resolution.
    var meDelayNanoseconds: UInt64 = 0

    // MARK: - Recording

    func record(_ call: Call) {
        lock.lock(); _calls.append(call); lock.unlock()
    }

    // MARK: - Refresh gate (single-flight testing)

    private let gateLock = NSLock()
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    /// When true, `refresh` records its call then suspends until
    /// `releaseRefreshGate()` is called. Used to test that concurrent
    /// `performRefresh` calls coalesce into a single network refresh.
    var refreshGateHeld = false

    /// Resumes every `refresh` call suspended on the gate.
    func releaseRefreshGate() {
        gateLock.lock()
        let waiters = refreshWaiters
        refreshWaiters.removeAll()
        gateLock.unlock()
        for w in waiters { w.resume(returning: ()) }
    }

    // MARK: - Attempt-aware canned server (fix-refresh-response-loss 3.4)

    /// When true, `refresh` behaves like the transactional backend: the first
    /// presentation of a live predecessor commits a rotation bound to the
    /// presented attempt; repeating the same predecessor + attempt returns
    /// the SAME successor (stable recovery); a different attempt (or none)
    /// for a revoked predecessor reports `token_reuse`; a replay after the
    /// successor rotated forward reports `refresh_attempt_completed`.
    ///
    /// Contract mirror — keep codes AND semantics in sync with the
    /// authoritative backend contract or these tests validate a fiction:
    /// `backend/api/openapi.yaml` (POST /auth/refresh responses + the
    /// refresh_attempt_id field), `backend/internal/handlers/auth.go`
    /// (`recoverRefresh` / `serveRecovery` / `rotateWithRecovery`), pinned
    /// by `backend/internal/contract/openapi_test.go`
    /// (canonicalErrorCodes + refresh-attempt pin), which fails CI on drift.
    var attemptAwareServerEnabled = false

    /// When true, the next committed rotation throws a transport error AFTER
    /// committing — the response-loss shape: the server rotated, the client
    /// never saw the successor.
    var dropNextAttemptResponse = false

    private struct AttemptRecord {
        let predecessor: String
        let successor: AuthSession
        var consumed: Bool
    }

    private var attemptRecords: [String: AttemptRecord] = [:]
    private var revokedTokens: Set<String> = []
    private var successorIndex = 0

    /// Synchronous entry point for the attempt-aware server: takes the lock
    /// itself so async callers never touch `NSLock` directly (Swift 6 mode).
    /// Runs fully synchronously — no suspension points inside.
    private func lockedAttemptAwareRefresh(refreshToken: String, attemptId: String) throws -> AuthSession {
        lock.lock()
        defer { lock.unlock() }
        return try attemptAwareRefresh(refreshToken: refreshToken, attemptId: attemptId)
    }

    /// The attempt-aware server logic itself. Call only with `lock` held via
    /// `lockedAttemptAwareRefresh`.
    private func attemptAwareRefresh(refreshToken: String, attemptId: String) throws -> AuthSession {
        if let record = attemptRecords[attemptId] {
            guard record.predecessor == refreshToken else {
                // Rebound attempt: rejected as a conflict without issuing
                // credentials or touching the original receipt.
                throw APIError.server(code: "refresh_attempt_conflict", message: "Attempt bound to another token")
            }
            if record.consumed {
                throw APIError.server(code: "refresh_attempt_completed", message: "Attempt already completed")
            }
            return record.successor
        }
        if revokedTokens.contains(refreshToken) {
            throw APIError.server(code: "token_reuse", message: "Token has been revoked. Sign in again.")
        }
        // Fresh rotation: consume the predecessor, record the receipt, and
        // close any receipt whose successor is being rotated forward.
        successorIndex += 1
        let successor = AuthSession(
            accessToken: "rec-at-\(successorIndex)",
            refreshToken: "rec-rt-\(successorIndex)",
            user: meResult.user
        )
        for id in attemptRecords.keys where attemptRecords[id]?.successor.refreshToken == refreshToken {
            attemptRecords[id]?.consumed = true
        }
        revokedTokens.insert(refreshToken)
        attemptRecords[attemptId] = AttemptRecord(
            predecessor: refreshToken,
            successor: successor,
            consumed: false
        )
        if dropNextAttemptResponse {
            dropNextAttemptResponse = false
            throw APIError.transport(underlying: "simulated truncated refresh response")
        }
        return successor
    }

    // MARK: - AuthRepository

    func requestOtp(email: String) async throws {
        record(.requestOtp(email: email))
        if let e = otpRequestError { throw e }
    }

    func verifyOtp(email: String, code: String) async throws -> AuthSession {
        record(.verifyOtp(email: email, code: code))
        if let e = otpVerifyError { throw e }
        return AuthSession(
            accessToken: otpVerifyResult.accessToken,
            refreshToken: otpVerifyResult.refreshToken,
            user: UserDTO(
                id: otpVerifyResult.user.id,
                email: email,
                emailVerified: otpVerifyResult.user.emailVerified
            ),
            accountStatusCredential: otpVerifyResult.accountStatusCredential,
            accountStatusExpiresAt: otpVerifyResult.accountStatusExpiresAt
        )
    }

    func appleSignIn(identityToken: String, authorizationCode: String? = nil) async throws -> AuthSession {
        record(.appleSignIn(identityToken: identityToken, authorizationCode: authorizationCode))
        if let e = appleSignInError { throw e }
        return appleSignInResult
    }

    func refresh(refreshToken: String, attemptId: String) async throws -> AuthSession {
        record(.refresh(refreshToken: refreshToken, attemptId: attemptId))
        if refreshGateHeld {
            await waitForGateRelease()
        }
        if attemptAwareServerEnabled {
            return try lockedAttemptAwareRefresh(refreshToken: refreshToken, attemptId: attemptId)
        }
        if let e = refreshError { throw e }
        return refreshResult
    }

    /// Suspends until `releaseRefreshGate()` resumes the waiter. The lock
    /// dance lives in synchronous helpers (Swift 6 mode forbids direct
    /// `NSLock` use from async contexts).
    private func waitForGateRelease() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.appendRefreshWaiter(cont)
        }
    }

    private func appendRefreshWaiter(_ continuation: CheckedContinuation<Void, Never>) {
        gateLock.lock()
        refreshWaiters.append(continuation)
        gateLock.unlock()
    }

    func logout() async throws {
        record(.logout)
        if let e = logoutError { throw e }
    }

    func me() async throws -> MeResponse {
        record(.me)
        if meDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: meDelayNanoseconds)
        }
        await meHook?()
        if let e = meError { throw e }
        return meResult
    }

    func deleteAccount() async throws -> AccountDeletionOutcome {
        record(.deleteAccount)
        if let e = deleteAccountError { throw e }
        return deleteAccountResult
    }

    func fetchAccountStatus(statusCredential: String) async throws -> AccountStatusResponse {
        record(.fetchAccountStatus)
        if let e = accountStatusError { throw e }
        return accountStatusResult
    }

    func acquireAppleDeletionCredential(identityToken: String, authorizationCode: String?) async throws {
        record(.acquireAppleDeletionCredential(identityToken: identityToken, authorizationCode: authorizationCode))
        if let e = deletionCredentialError { throw e }
    }

}
