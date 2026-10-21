import Foundation

/// Durable refresh-attempt identity (device-sessions spec): one unpredictable
/// identifier per logical rotation, minted before the first network send and
/// reused across suspension, restart, and failed credential writes until a
/// complete successor snapshot is durably saved.
enum RefreshAttempt {
    /// Mints an unpredictable UUIDv7 identifier (48-bit unix-millis +
    /// 74 random bits, version/variant bits set). Unpredictability matters:
    /// a replayable attempt would let a lost response be mistaken for theft.
    static func newID() -> String {
        // Clamped: UInt64(Double) traps on negative values, and a device
        // clock set before 1970 must mint a usable id, not crash auth.
        // UUIDv7 tolerates a clamped timestamp far better than a trap.
        let millis = UInt64(max(0, Date().timeIntervalSince1970) * 1_000)
        var rng = SystemRandomNumberGenerator()
        let randA = UInt16.random(in: 0 ... 0x0FFF, using: &rng)
        let randB = UInt64.random(in: 0 ... 0x3FFF_FFFF_FFFF_FFFF, using: &rng)
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0 ..< 6 {
            bytes[i] = UInt8((millis >> (8 * (5 - i))) & 0xFF)
        }
        bytes[6] = 0x70 | UInt8((randA >> 8) & 0x0F)
        bytes[7] = UInt8(randA & 0xFF)
        bytes[8] = 0x80 | UInt8((randB >> 56) & 0x3F)
        for i in 9 ..< 16 {
            bytes[i] = UInt8((randB >> (8 * (15 - i))) & 0xFF)
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    }

    /// Codes that conclusively end the session (revocation / exhaustion):
    /// the only refresh failures that clear local state.
    static let revocationCodes: Set<String> = ["invalid_refresh", "token_reuse", "refresh_expired"]

    /// A delayed duplicate of a closed attempt: the successor already rotated
    /// forward. Never revocation — the client keeps its durable credentials.
    static let completedCode = "refresh_attempt_completed"
}
