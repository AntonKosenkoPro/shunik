import Testing
import AuthenticationServices
import Foundation
@testable import Shunik

/// Native Apple revocation observation (account-deletion spec 5.4):
/// `.revoked` signs out with local data intact, scoped to the current
/// authentication method + account + generation. Stale callbacks, other
/// states, and non-Apple sessions never sign out and never imply deletion.
@MainActor
@Suite("Apple credential observer", .serialized)
struct AppleCredentialObserverTests {

    final class FakeStateProvider: AppleCredentialStateProviding, @unchecked Sendable {
        var state: AppleCredentialState = .authorized
        private let lock = NSLock()
        private(set) var queriedUserIDs: [String] = []

        func credentialState(forUserID userID: String) async -> AppleCredentialState {
            recordQuery(userID)
            return currentState()
        }

        /// Synchronous lock dance (Swift 6 mode forbids direct `NSLock`
        /// use from async contexts).
        private func recordQuery(_ userID: String) {
            lock.lock(); queriedUserIDs.append(userID); lock.unlock()
        }

        private func currentState() -> AppleCredentialState {
            lock.lock(); defer { lock.unlock() }
            return state
        }
    }

    final class SignOutBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var accountIDs: [String] = []
        func record(_ id: String) {
            lock.lock(); accountIDs.append(id); lock.unlock()
        }
    }

    private func signIn(
        _ sessionStore: SessionStore,
        _ keychain: InMemoryKeychainStore,
        accountID: String = "u1",
        appleUserID: String? = "apple-sub-1"
    ) async {
        sessionStore.setSignedIn(CachedSession(id: accountID, email: "a@b.com", emailVerified: true))
        if let appleUserID {
            await keychain.setString(appleUserID, for: .appleUserId)
        } else {
            await keychain.remove(key: .appleUserId)
        }
    }

    @Test("revoked signs out the observed account")
    func revokedSignsOut() async {
        let keychain = InMemoryKeychainStore()
        let sessionStore = SessionStore()
        let provider = FakeStateProvider()
        provider.state = .revoked
        let box = SignOutBox()
        let observer = AppleCredentialObserver(
            stateProvider: provider, keychain: keychain, sessionStore: sessionStore
        ) { box.record($0) }
        await signIn(sessionStore, keychain)
        await observer.start(accountID: "u1")
        await observer.checkNow()
        #expect(box.accountIDs == ["u1"])
    }

    @Test("authorized does not sign out")
    func authorizedIgnores() async {
        let keychain = InMemoryKeychainStore()
        let sessionStore = SessionStore()
        let provider = FakeStateProvider()
        provider.state = .authorized
        let box = SignOutBox()
        let observer = AppleCredentialObserver(
            stateProvider: provider, keychain: keychain, sessionStore: sessionStore
        ) { box.record($0) }
        await signIn(sessionStore, keychain)
        await observer.start(accountID: "u1")
        await observer.checkNow()
        #expect(box.accountIDs.isEmpty)
    }

    @Test("notFound, transferred, and unknown never sign out")
    func otherStatesIgnore() async {
        for state: AppleCredentialState in [.notFound, .transferred, .unknown] {
            let keychain = InMemoryKeychainStore()
            let sessionStore = SessionStore()
            let provider = FakeStateProvider()
            provider.state = state
            let box = SignOutBox()
            let observer = AppleCredentialObserver(
                stateProvider: provider, keychain: keychain, sessionStore: sessionStore
            ) { box.record($0) }
            await signIn(sessionStore, keychain)
            await observer.start(accountID: "u1")
            await observer.checkNow()
            #expect(box.accountIDs.isEmpty, "state \(state) must not sign out")
        }
    }

    @Test("inactive without a native Apple user id")
    func noAppleUserIdStaysInactive() async {
        let keychain = InMemoryKeychainStore()
        let sessionStore = SessionStore()
        let provider = FakeStateProvider()
        let box = SignOutBox()
        let observer = AppleCredentialObserver(
            stateProvider: provider, keychain: keychain, sessionStore: sessionStore
        ) { box.record($0) }
        sessionStore.setSignedIn(CachedSession(id: "u1", email: "a@b.com", emailVerified: true))
        await keychain.remove(key: .appleUserId)
        await observer.start(accountID: "u1")
        #expect(!observer.isObserving)
        await observer.checkNow()
        #expect(box.accountIDs.isEmpty)
    }

    @Test("stale observation after account switch never clears the new session")
    func staleObservationIgnored() async {
        let keychain = InMemoryKeychainStore()
        let sessionStore = SessionStore()
        let provider = FakeStateProvider()
        provider.state = .revoked
        let box = SignOutBox()
        let observer = AppleCredentialObserver(
            stateProvider: provider, keychain: keychain, sessionStore: sessionStore
        ) { box.record($0) }
        await signIn(sessionStore, keychain)
        await observer.start(accountID: "u1")
        observer.stop()
        // A new Apple session for another account signs in; the old
        // observation is dead and no fresh observation started for it.
        await signIn(sessionStore, keychain, accountID: "u2", appleUserID: "apple-sub-2")
        await observer.checkNow()
        #expect(box.accountIDs.isEmpty)
        await observer.start(accountID: "u2")
        await observer.checkNow()
        #expect(box.accountIDs == ["u2"])
    }

    @Test("queries the native Apple user, never the Shunik UUID")
    func queriesNativeAppleUser() async {
        let keychain = InMemoryKeychainStore()
        let sessionStore = SessionStore()
        let provider = FakeStateProvider()
        let box = SignOutBox()
        let observer = AppleCredentialObserver(
            stateProvider: provider, keychain: keychain, sessionStore: sessionStore
        ) { box.record($0) }
        await signIn(sessionStore, keychain)
        await observer.start(accountID: "u1")
        await observer.checkNow()
        #expect(provider.queriedUserIDs == ["apple-sub-1"])
    }

    @Test("revocation notification is confirmed before acting")
    func revocationNotificationConfirmed() async throws {
        let keychain = InMemoryKeychainStore()
        let sessionStore = SessionStore()
        let provider = FakeStateProvider()
        provider.state = .revoked
        let box = SignOutBox()
        let observer = AppleCredentialObserver(
            stateProvider: provider, keychain: keychain, sessionStore: sessionStore
        ) { box.record($0) }
        await signIn(sessionStore, keychain)
        await observer.start(accountID: "u1")
        NotificationCenter.default.post(
            name: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
            object: nil
        )
        // The sink hops to a Task: poll briefly instead of sleeping.
        for _ in 0..<100 where box.accountIDs.isEmpty {
            await Task.yield()
        }
        #expect(box.accountIDs == ["u1"])
    }

    @Test("revocation notification with a healthy credential does nothing")
    func revocationNotificationHealthyIgnored() async throws {
        let keychain = InMemoryKeychainStore()
        let sessionStore = SessionStore()
        let provider = FakeStateProvider()
        provider.state = .authorized
        let box = SignOutBox()
        let observer = AppleCredentialObserver(
            stateProvider: provider, keychain: keychain, sessionStore: sessionStore
        ) { box.record($0) }
        await signIn(sessionStore, keychain)
        await observer.start(accountID: "u1")
        NotificationCenter.default.post(
            name: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
            object: nil
        )
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(box.accountIDs.isEmpty)
    }
}
