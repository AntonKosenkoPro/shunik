import Testing
import Foundation
@testable import Shunik

@Suite("DeviceIdentityStore")
struct DeviceIdentityStoreTests {

    @Test("mints once and returns the same id on repeated calls")
    func sameUUIDTwice() async throws {
        let keychain = InMemoryKeychainStore()
        let store = DeviceIdentityStore(keychain: keychain)

        let first = await store.current()
        let second = await store.current()

        #expect(first == second)
        try #require(UUID(uuidString: first) != nil, "device id must be a UUID")
    }

    @Test("persists the id in the keychain across store instances")
    func persistsAcrossLaunches() async throws {
        let keychain = InMemoryKeychainStore()
        let first = await DeviceIdentityStore(keychain: keychain).current()
        // A second instance models a fresh process reading the same Keychain.
        let second = await DeviceIdentityStore(keychain: keychain).current()

        #expect(first == second)
    }

    @Test("empty keychain value is re-minted, not reused")
    func remintsOnMissingValue() async throws {
        // Simulates a new phone whose Keychain restore carried nothing for
        // the device id: a fresh identifier is minted for that device.
        let keychain = InMemoryKeychainStore(initial: [.deviceId: ""])
        let store = DeviceIdentityStore(keychain: keychain)

        let id = await store.current()

        try #require(UUID(uuidString: id) != nil)
        #expect(await keychain.string(for: .deviceId) == id)
    }
}
