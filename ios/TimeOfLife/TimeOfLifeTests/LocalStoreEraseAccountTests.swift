import Testing
import Foundation
@testable import TimeOfLife

/// Account-scoped file deletion (account-bound-store + account-deletion
/// specs): `eraseAccount(userID:)` removes exactly one account's database
/// with its SQLite sidecars — active or dormant — and never touches other
/// accounts' files or the stable device identity. `eraseAll` keeps its
/// active-file-only contract and now covers sidecars too.
@Suite("LocalStore eraseAccount")
struct LocalStoreEraseAccountTests {

    private func temporaryBase() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func sidecars(of url: URL) -> [URL] {
        ["-wal", "-shm", "-journal"].map { URL(fileURLWithPath: url.path + $0) }
    }

    @Test("erases the active account and unbinds")
    func erasesActiveAccount() async throws {
        let dir = temporaryBase()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = LocalStore.databaseURL(userID: "erase-active-a", in: dir)
        let bound = try LocalStore(url: url, userID: "erase-active-a")
        _ = try await bound.categories()
        try await bound.eraseAccount(userID: "erase-active-a", in: dir)
        #expect(!fileExists(url))
    }

    @Test("erases a dormant account without touching the active store")
    func erasesDormantAccount() async throws {
        let base = temporaryBase()
        let activeURL = LocalStore.databaseURL(userID: "erase-dorm-a", in: base)
        let dormantURL = LocalStore.databaseURL(userID: "erase-dorm-b", in: base)
        let active = try LocalStore(url: activeURL, userID: "erase-dorm-a")
        let dormant = try LocalStore(url: dormantURL, userID: "erase-dorm-b")
        _ = try await active.categories()
        _ = try await dormant.categories()
        try await active.eraseAccount(userID: "erase-dorm-b", in: base)
        #expect(!fileExists(dormantURL))
        #expect(fileExists(activeURL))
        // The active store still serves its own account.
        _ = try await active.categories()
    }

    @Test("removes SQLite sidecars with the file")
    func removesSidecars() async throws {
        let base = temporaryBase()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = LocalStore.databaseURL(userID: "erase-side-a", in: base)
        let store = try LocalStore(url: url, userID: "erase-side-a")
        _ = try await store.categories()
        for sidecar in sidecars(of: url) {
            FileManager.default.createFile(atPath: sidecar.path, contents: Data("x".utf8))
        }
        try await store.eraseAccount(userID: "erase-side-a", in: base)
        #expect(!fileExists(url))
        for sidecar in sidecars(of: url) {
            #expect(!fileExists(sidecar))
        }
    }

    @Test("missing file and sidecars are success")
    func missingFileIsSuccess() async throws {
        let base = temporaryBase()
        let store = LocalStore()
        try await store.eraseAccount(userID: "erase-missing-a", in: base)
    }

    @Test("invalid user ids are rejected without touching files")
    func invalidUserIDRejected() async {
        let base = temporaryBase()
        let store = LocalStore()
        do {
            try await store.eraseAccount(userID: "../escape", in: base)
            Issue.record("expected invalidUserID")
        } catch let error as LocalStore.LocalStoreError {
            #expect(error == .invalidUserID)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test("eraseAll removes sidecars of the active file")
    func eraseAllRemovesSidecars() async throws {
        let dir = temporaryBase()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(LocalStore.databaseFileName(userID: "erase-all-a"))
        // eraseAll targets boundURL/lastBoundURL: bind by opening through
        // the account path, then close so lastBoundURL retains it.
        _ = try LocalStore(url: url, userID: "erase-all-a")
        for sidecar in sidecars(of: url) {
            FileManager.default.createFile(atPath: sidecar.path, contents: Data("x".utf8))
        }
        // Reopen as the active store via the same file, then erase.
        let store = try LocalStore(url: url, userID: "erase-all-a")
        try await store.eraseAll()
        #expect(!fileExists(url))
        for sidecar in sidecars(of: url) {
            #expect(!fileExists(sidecar))
        }
    }
}
