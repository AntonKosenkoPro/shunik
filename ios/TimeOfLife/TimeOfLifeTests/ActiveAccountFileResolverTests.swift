import Testing
import Foundation
@testable import TimeOfLife

/// Lock-screen-controls delta + account-bound-store tests (account-bound-
/// local-data 4.2/4.3): control surfaces resolve the ACTIVE account's file
/// only — signed-out/unbound resolves locked, never anon or dormant-account
/// data, and no file is ever created as a side effect.
@Suite("ActiveAccountFileResolver")
struct ActiveAccountFileResolverTests {

    private func temporaryBaseDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
    }

    private func makeDefaults(userID: String?) -> UserDefaults {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        if let userID {
            defaults.set(userID, forKey: "com.shunik.session.id")
        }
        return defaults
    }

    @Test("no shared-session user id resolves locked (signed out at the gate)")
    func signedOutResolvesLocked() {
        let base = temporaryBaseDirectory()
        let resolver = ActiveAccountFileResolver(
            sessionDefaults: makeDefaults(userID: nil)
        )
        #expect(resolver.resolve(base: base) == .locked)
    }

    @Test("the active account's existing file resolves ready with its URL")
    func activeFileResolvesReady() throws {
        let base = temporaryBaseDirectory()
        // An explicit placeholder file: resolution only stats existence —
        // no store side effects involved.
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let fileURL = base.appendingPathComponent(LocalStore.databaseFileName(userID: "u1"))
        _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let resolver = ActiveAccountFileResolver(
            sessionDefaults: makeDefaults(userID: "u1")
        )
        guard case let .ready(url) = resolver.resolve(base: base) else {
            Issue.record("expected ready, got \(resolver.resolve(base: base))")
            return
        }
        #expect(url == base.appendingPathComponent(LocalStore.databaseFileName(userID: "u1")))
    }

    @Test("a session user id whose file is absent resolves noData and creates nothing")
    func missingFileResolvesNoDataWithoutCreating() throws {
        let base = temporaryBaseDirectory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let resolver = ActiveAccountFileResolver(
            sessionDefaults: makeDefaults(userID: "u2")
        )
        #expect(resolver.resolve(base: base) == .noData)
        // No anonymous or dormant file was created by resolution.
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
    }

    @Test("a dormant account's file is never resolved for another active account")
    func dormantFileNeverResolvesForOtherAccount() async throws {
        let base = temporaryBaseDirectory()
        // A's file exists but the shared-session user is B: only B's file may
        // ever be resolved — A's stays dormant and unread.
        // swiftlint:disable:next force_try
        let dormantA = try! LocalStore(
            url: base.appendingPathComponent(LocalStore.databaseFileName(userID: "user-a")),
            userID: "user-a"
        )
        try await dormantA.setLastSyncedAt(resource: "scaffold", date: Date())
        await dormantA.closeAccount()

        let resolver = ActiveAccountFileResolver(
            sessionDefaults: makeDefaults(userID: "user-b")
        )
        #expect(resolver.resolve(base: base) == .noData)
    }

    @Test("an unsanitizable session user id resolves locked")
    func invalidUserIDResolvesLocked() {
        let base = temporaryBaseDirectory()
        let resolver = ActiveAccountFileResolver(
            sessionDefaults: makeDefaults(userID: "../evil")
        )
        #expect(resolver.resolve(base: base) == .locked)
    }

    @Test("sidecar file id resolves ready with empty defaults (extension case)")
    func sidecarFileResolvesWithoutDefaults() throws {
        let base = temporaryBaseDirectory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let fileURL = base.appendingPathComponent(LocalStore.databaseFileName(userID: "u9"))
        _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        try "u9".write(
            to: base.appendingPathComponent(ActiveAccountFileResolver.sessionFileName),
            atomically: true,
            encoding: .utf8
        )
        let resolver = ActiveAccountFileResolver(
            sessionDefaults: makeDefaults(userID: nil)
        )
        guard case let .ready(url) = resolver.resolve(base: base) else {
            Issue.record("expected ready, got \(resolver.resolve(base: base))")
            return
        }
        #expect(url == base.appendingPathComponent(LocalStore.databaseFileName(userID: "u9")))
    }

    @Test("sidecar file takes precedence over defaults")
    func sidecarFileBeatsDefaults() throws {
        let base = temporaryBaseDirectory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let fileURL = base.appendingPathComponent(LocalStore.databaseFileName(userID: "u9"))
        _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        try "u9".write(
            to: base.appendingPathComponent(ActiveAccountFileResolver.sessionFileName),
            atomically: true,
            encoding: .utf8
        )
        let resolver = ActiveAccountFileResolver(
            sessionDefaults: makeDefaults(userID: "u1")
        )
        guard case let .ready(url) = resolver.resolve(base: base) else {
            Issue.record("expected ready, got \(resolver.resolve(base: base))")
            return
        }
        #expect(url == base.appendingPathComponent(LocalStore.databaseFileName(userID: "u9")))
    }
}
