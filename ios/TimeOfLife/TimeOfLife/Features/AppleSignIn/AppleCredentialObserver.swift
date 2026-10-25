import AuthenticationServices
import Combine
import Foundation

/// Native Apple credential state for the current session (account-deletion
/// spec 5.4, `apple-signin` external-revocation contract).
enum AppleCredentialState: Equatable, Sendable {
    /// The Apple ID is still authorized for this app.
    case authorized
    /// The user revoked the app's Apple authorization (Settings or the
    /// `credentialRevokedNotification`). Signs out with local data intact —
    /// never account deletion.
    case revoked
    /// No credential for this Apple user id on this device / transferred to
    /// another account / unknown future state. All ignored: never sign-out,
    /// never deletion evidence.
    case notFound
    case transferred
    case unknown
}

/// Indirection over `ASAuthorizationAppleIDProvider.getCredentialState` so
/// observation is unit-testable without Apple IDs or devices. The native API
/// requires the NATIVE Apple user identifier (`ASAuthorizationAppleIDCredential.user`),
/// never the Shunik account UUID — callers pass the separately preserved
/// native id. Official docs: AuthenticationServices
/// `ASAuthorizationAppleIDProvider.credentialState(forUserID:)` (async,
/// available iOS 13+), `credentialRevokedNotification` (means sign-out),
/// `ASAuthorizationError.Code.canceled`
/// (developer.apple.com/tutorials/data/documentation/authenticationservices/,
/// pin iOS 18 SDK via Xcode 16+).
protocol AppleCredentialStateProviding: Sendable {
    func credentialState(forUserID userID: String) async -> AppleCredentialState
}

/// Production provider backed by `ASAuthorizationAppleIDProvider`.
struct LiveAppleCredentialStateProvider: AppleCredentialStateProviding {
    func credentialState(forUserID userID: String) async -> AppleCredentialState {
        // A throwing lookup (revoked daemon, transport failure, future
        // mismatch) resolves to `.unknown` — ignored by the observer, never
        // sign-out and never deletion evidence.
        guard let state = try? await ASAuthorizationAppleIDProvider().credentialState(forUserID: userID) else {
            return .unknown
        }
        switch state {
        case .authorized: return .authorized
        case .revoked: return .revoked
        case .notFound: return .notFound
        case .transferred: return .transferred
        @unknown default: return .unknown
        }
    }
}

/// Observes native Apple revocation for the CURRENT Apple-authenticated
/// session only (task 5.4).
///
/// Scope: started with the Shunik account id plus a lifecycle generation.
/// Callbacks (notification or explicit check) sign out only when all three
/// still match — the stored native Apple user id exists (i.e. this device
/// signed in via Apple, never inferred from email suffix or `has_apple_identity`),
/// the session is still signed in as the observed account, and the
/// generation is current. Stale callbacks (account switch, sign-out,
/// restart) are ignored and can never clear a new session, end another
/// account's Live Activity, or delete data.
///
/// A `.revoked` verdict (or the revocation notification) performs a
/// file-preserving sign-out: sessions end, the Shunik identity, server data,
/// and all local files stay intact, and reauthorizing the same Apple
/// identity returns to the existing account. `.notFound` / `.transferred` /
/// `.unknown` never sign out and are never interpreted as account deletion —
/// neither is any transport failure (the provider is non-throwing by design).
@MainActor
final class AppleCredentialObserver {
    private let stateProvider: AppleCredentialStateProviding
    private let keychain: KeychainStoring
    private let sessionStore: SessionStore
    /// File-preserving sign-out for the observed account (sessions end,
    /// files stay). Wired to `AuthService.logout` + coordinator fence
    /// release in production; a recording closure in tests. Receives the
    /// verified observed account id.
    private let signOut: (String) async -> Void

    /// Monotonic lifecycle: bumped on every `stop()`, so callbacks captured
    /// by an older observation can never act on a newer session.
    private var generation: UInt64 = 0
    /// The Shunik account id under observation (nil = inactive).
    private var observedAccountID: String?
    private var notificationCancellable: AnyCancellable?

    init(
        stateProvider: AppleCredentialStateProviding,
        keychain: KeychainStoring,
        sessionStore: SessionStore,
        signOut: @escaping (String) async -> Void
    ) {
        self.stateProvider = stateProvider
        self.keychain = keychain
        self.sessionStore = sessionStore
        self.signOut = signOut
    }

    /// Starts observation for one Apple-authenticated account. No-op when
    /// this device holds no native Apple user id (the current session is not
    /// Apple-authenticated here, whatever the account's `has_apple_identity`
    /// metadata says).
    func start(accountID: String) async {
        guard await keychain.string(for: .appleUserId) != nil else { return }
        generation &+= 1
        observedAccountID = accountID
        notificationCancellable = NotificationCenter.default
            .publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)
            .sink { [weak self] _ in
                Task { await self?.handleRevocationNotification() }
            }
    }

    /// Stops observation and invalidates in-flight callbacks.
    func stop() {
        generation &+= 1
        observedAccountID = nil
        notificationCancellable?.cancel()
        notificationCancellable = nil
    }

    /// Test observability: whether an account is currently observed.
    var isObserving: Bool { observedAccountID != nil }

    /// One explicit credential-state check for the observed account (e.g. on
    /// foreground or after Apple sign-in). `.revoked` signs out with files
    /// intact; every other state is ignored.
    func checkNow() async {
        let generation = generation
        guard let accountID = observedAccountID,
              let appleUserID = await keychain.string(for: .appleUserId) else { return }
        let state = await stateProvider.credentialState(forUserID: appleUserID)
        guard state == .revoked else { return }
        await signOutIfCurrent(accountID: accountID, generation: generation)
    }

    private func handleRevocationNotification() async {
        let generation = generation
        guard let accountID = observedAccountID else { return }
        // The notification carries no identity: confirm the observed Apple
        // user is still authorized-state-revoked before acting, so a stray
        // notification can never sign out a fresh session. A missing Apple
        // user id means this device is no longer Apple-authenticated —
        // ignore.
        guard let appleUserID = await keychain.string(for: .appleUserId) else { return }
        let state = await stateProvider.credentialState(forUserID: appleUserID)
        guard state == .revoked else { return }
        await signOutIfCurrent(accountID: accountID, generation: generation)
    }

    /// Signs out only when the observed account is still the signed-in
    /// account and the generation is still current. Anything else is a stale
    /// callback and is dropped without touching the new session.
    private func signOutIfCurrent(accountID: String, generation: UInt64) async {
        guard generation == self.generation,
              observedAccountID == accountID,
              case let .signedIn(current) = sessionStore.state,
              current.id == accountID else { return }
        await signOut(accountID)
    }
}
