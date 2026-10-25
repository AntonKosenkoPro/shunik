import Foundation

/// Describes a single API request in terms the `APIClient` can turn into a
/// `URLRequest`. Endpoints are value types — easy to assert against in tests.
struct APIEndpoint: Equatable, Sendable {
    let method: HTTPMethod
    let path: String
    let body: Data?
    let requiresAuth: Bool
    /// Explicit Bearer token for endpoints that do NOT use the session access
    /// token (account-status checks present the status credential, never the
    /// login token). When set, it wins over `accessTokenProvider` and the
    /// request never triggers the refresh-and-retry path.
    let customBearer: String?

    init(method: HTTPMethod, path: String, body: Encodable? = nil, requiresAuth: Bool = false, customBearer: String? = nil) {
        self.method = method
        self.path = path
        self.requiresAuth = requiresAuth
        self.customBearer = customBearer
        self.body = APIEndpoint.encode(body)
    }

    /// Convenience for endpoints with no body.
    static func value(method: HTTPMethod, path: String, requiresAuth: Bool = false, customBearer: String? = nil) -> APIEndpoint {
        APIEndpoint(method: method, path: path, body: Optional<EmptyBody>.none, requiresAuth: requiresAuth, customBearer: customBearer)
    }

    private static func encode(_ body: Encodable?) -> Data? {
        guard let body else { return nil }
        do {
            return try JSONEncoder().encode(AnyEncodable(body))
        } catch {
            assertionFailure("Failed to encode endpoint body: \(error)")
            return nil
        }
    }
}

/// Empty JSON body marker.
struct EmptyBody: Encodable, Equatable, Sendable {}
