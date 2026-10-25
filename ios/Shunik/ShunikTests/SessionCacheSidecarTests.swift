import Testing
import Foundation
@testable import Shunik

/// SessionCache sidecar mirror (live-activities Stop-intent fix):
/// sign-in writes the user id to the group-container file the resolver
/// reads file-first, sign-out removes it. Defaults-only behavior is
/// unchanged when no file URL is wired (tests, previews, UI-testing).
@Suite("SessionCache sidecar")
struct SessionCacheSidecarTests {

    @Test("save mirrors the user id to the sidecar file")
    func saveWritesSidecar() throws {
        let dir = try temporaryDirectory()
        let fileURL = dir.appendingPathComponent(ActiveAccountFileResolver.sessionFileName)
        let cache = SessionCache(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            sessionFileURL: fileURL
        )

        cache.save(CachedSession(id: "u1", email: "a@b.c", emailVerified: true))

        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "u1")
    }

    @Test("save(nil) removes the sidecar file")
    func clearRemovesSidecar() throws {
        let dir = try temporaryDirectory()
        let fileURL = dir.appendingPathComponent(ActiveAccountFileResolver.sessionFileName)
        let cache = SessionCache(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            sessionFileURL: fileURL
        )
        cache.save(CachedSession(id: "u1", email: "a@b.c", emailVerified: true))

        cache.save(nil)

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("cache save plus resolver read round-trips to ready (production wiring)")
    func saveThenResolveIsReady() throws {
        let dir = try temporaryDirectory()
        // swiftlint:disable:next force_try
        let store = try! LocalStore(
            url: dir.appendingPathComponent(LocalStore.databaseFileName(userID: "u1")),
            userID: "u1"
        )
        _ = store
        let cache = SessionCache(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            sessionFileURL: dir.appendingPathComponent(ActiveAccountFileResolver.sessionFileName)
        )
        cache.save(CachedSession(id: "u1", email: "a@b.c", emailVerified: true))

        let resolver = ActiveAccountFileResolver(
            sessionDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        guard case let .ready(url) = resolver.resolve(base: dir) else {
            Issue.record("expected ready, got \(resolver.resolve(base: dir))")
            return
        }
        #expect(url == dir.appendingPathComponent(LocalStore.databaseFileName(userID: "u1")))
    }

    private func temporaryDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
