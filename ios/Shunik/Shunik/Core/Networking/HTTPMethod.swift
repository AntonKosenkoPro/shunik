import Foundation

/// HTTP verbs used by the API client. Modeled as a value type so endpoints
/// are easy to construct and test against.
enum HTTPMethod: String, Equatable, Sendable {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case delete = "DELETE"
}
