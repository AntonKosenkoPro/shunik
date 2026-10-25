import Foundation

/// Abstraction over the network client so `RemoteAuthRepository` can be tested
/// with a mock and production can use `APIClient`.
protocol APISending: Sendable {
    func send<T: Decodable & Sendable>(_ endpoint: APIEndpoint, as: T.Type) async throws -> T
    func sendVoid(_ endpoint: APIEndpoint) async throws
    /// Sends an endpoint and returns the raw body with its HTTP status code.
    /// Used where the status itself carries meaning (`DELETE /auth/account`:
    /// 204 completed vs 202 pending Apple revocation). Non-2xx responses
    /// throw the same envelope errors as `send`.
    func sendRaw(_ endpoint: APIEndpoint) async throws -> (data: Data, statusCode: Int)
}
