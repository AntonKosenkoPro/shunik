import Foundation

/// Type-erased encodable wrapper so callers can encode any `Encodable`
/// (outbox payloads in `LocalStore`, request bodies in `APIEndpoint`).
/// Lives here (not in networking) because the widget extension compiles it
/// without dragging the networking layer (live-activities change).
struct AnyEncodable: Encodable {
    private let encode: (Encoder) throws -> Void
    init(_ wrapped: Encodable) {
        self.encode = wrapped.encode
    }
    func encode(to encoder: Encoder) throws { try encode(encoder) }
}
