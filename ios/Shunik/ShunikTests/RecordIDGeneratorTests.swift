import Testing
import Foundation
@testable import Shunik

/// Deterministic generator for tests: emits a sequence of ids so ordering and
/// injection are observable.
final class SequenceIDGenerator: RecordIDGenerating, @unchecked Sendable {
    let ids: [String]
    private let lock = NSLock()
    private var index = 0

    init(_ ids: [String]) {
        self.ids = ids
    }

    func newID() -> String {
        lock.lock()
        defer { lock.unlock() }
        let result = ids[index % ids.count]
        index += 1
        return result
    }
}

@Suite("UUIDv7Generator")
struct UUIDv7GeneratorTests {

    private let uuidV7Pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"

    @Test("generated ids are canonical lowercase UUID v7")
    func generatesUUIDv7() throws {
        let generator = UUIDv7Generator()
        for _ in 0..<50 {
            let id = generator.newID()
            #expect(id.range(of: uuidV7Pattern, options: .regularExpression) != nil,
                    "id \(id) is not a lowercase UUID v7")
        }
    }

    @Test("ids are unique")
    func unique() {
        let generator = UUIDv7Generator()
        var seen = Set<String>()
        for _ in 0..<500 {
            seen.insert(generator.newID())
        }
        #expect(seen.count == 500)
    }

    @Test("format produces the canonical 8-4-4-4-12 layout")
    func formatLayout() {
        let bytes: [UInt8] = Array(repeating: 0xab, count: 16)
        let formatted = UUIDv7Generator.format(bytes)
        #expect(formatted == "abababab-abab-abab-abab-abababababab")
        #expect(formatted.count == 36)
    }

    @Test("version and variant bits are set")
    func versionAndVariant() {
        let generator = UUIDv7Generator()
        for _ in 0..<20 {
            let id = generator.newID()
            // Version nibble: character at index 14 must be 7.
            let version = String(id[id.index(id.startIndex, offsetBy: 14)])
            #expect(version == "7")
            // Variant nibble: character at index 19 must be 8, 9, a, or b.
            let variant = String(id[id.index(id.startIndex, offsetBy: 19)])
            #expect(["8", "9", "a", "b"].contains(variant))
        }
    }

    @Test("ids are time-ordered within the same millisecond window")
    func timeOrdered() {
        let generator = UUIDv7Generator()
        var ids: [String] = []
        for _ in 0..<100 {
            ids.append(generator.newID())
        }
        #expect(ids == ids.sorted(), "UUID v7 ids must be time-ordered")
    }
}

@Suite("RecordID injection")
struct RecordIDInjectionTests {

    @Test("newRecordID exposes the injected generator")
    func newRecordIDUsesInjected() async throws {
        let generator = SequenceIDGenerator(["seq-1", "seq-2"])
        let store = try LocalStore(
            url: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
                .appendingPathComponent(LocalStore.databaseFileName(householdID: "u1")),
            recordIDGenerator: generator
        )
        let first = await store.newRecordID()
        let second = await store.newRecordID()
        #expect(first == "seq-1")
        #expect(second == "seq-2")
    }
}
