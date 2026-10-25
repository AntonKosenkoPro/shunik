import Foundation

/// Generates the client record identifiers used for relay resources
/// (category-management D3): lowercase UUID v7 strings, matching the
/// authoritative OpenAPI `format: uuid` + v7 validator. One dependency-
/// injectable generator is used for new Categories, Activities, and Entries
/// so tests can inject deterministic ids.
protocol RecordIDGenerating: Sendable {
    /// A new lowercase UUID v7 string.
    func newID() -> String
}

/// Default generator: real UUID v7 (time-ordered, RFC 4122 variant).
/// The first 48 bits are the Unix timestamp in milliseconds; the remaining
/// 74 bits are random with the version (7) and variant (10) bits set. Ids
/// generated within the same millisecond carry a monotonic counter in the
/// lower bits so they stay strictly ordered.
final class UUIDv7Generator: RecordIDGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var lastMillis: UInt64 = 0
    private var counter: UInt64 = 0

    func newID() -> String {
        lock.lock()
        defer { lock.unlock() }
        let millis = UInt64(Date().timeIntervalSince1970 * 1000)
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // Monotonic counter within the same millisecond: ids remain strictly
        // time-ordered even for rapid consecutive calls.
        if millis == lastMillis {
            counter += 1
        } else {
            lastMillis = millis
            counter = 0
        }
        // The counter occupies the low 14 bits of the random portion
        // (bytes 6-7), where the version nibble is already set in byte 6.
        let c = counter & 0x3FFF
        bytes[6] = (bytes[6] & 0xF0) | UInt8((c >> 8) & 0x0F)
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[7] = UInt8(c & 0xFF)
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return Self.format(millis: millis, bytes: bytes)
    }

    /// Formats the 48-bit millis timestamp plus 80 random bits as a
    /// lowercase canonical UUID v7 string.
    static func format(millis: UInt64, bytes: [UInt8]) -> String {
        var out = [UInt8](repeating: 0, count: 16)
        out[0] = UInt8((millis >> 40) & 0xFF)
        out[1] = UInt8((millis >> 32) & 0xFF)
        out[2] = UInt8((millis >> 24) & 0xFF)
        out[3] = UInt8((millis >> 16) & 0xFF)
        out[4] = UInt8((millis >> 8) & 0xFF)
        out[5] = UInt8(millis & 0xFF)
        for i in 6..<16 {
            out[i] = bytes[i]
        }
        let hex = out.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-"
            + "\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-"
            + "\(hex.dropFirst(20))"
    }

    /// Formats 16 fully-random bytes as a lowercase canonical UUID string
    /// (used by tests for layout assertions).
    static func format(_ bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-"
            + "\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-"
            + "\(hex.dropFirst(20))"
    }
}
