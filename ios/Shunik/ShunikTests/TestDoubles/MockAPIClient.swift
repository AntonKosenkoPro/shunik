import Foundation
@testable import Shunik

/// Records endpoints and returns canned decoded results / errors. Conforms
/// to `APISending` so `RemoteAuthRepository` can be tested without a network.
///
/// Thread-safe via `NSLock`.
final class MockAPIClient: APISending, @unchecked Sendable {

    /// A recorded endpoint invocation.
    struct Received: Equatable {
        let method: HTTPMethod
        let path: String
        let requiresAuth: Bool
        let body: Data?
        /// Explicit Bearer token for status-scheme endpoints (nil = session
        /// token or unauthenticated).
        let customBearer: String?
    }

    // MARK: - State

    private let lock = NSLock()
    private var _received: [Received] = []

    /// All recorded endpoint invocations, in order.
    var received: [Received] {
        lock.lock(); defer { lock.unlock() }
        return _received
    }

    /// Number of times `send` was called.
    private(set) var sendCallCount = 0
    /// Number of times `sendVoid` was called.
    private(set) var sendVoidCallCount = 0

    /// If set, `send` will throw this error instead of returning a result.
    var throwError: Error?

    /// Canned result for `send`. The closure receives the requested type and endpoint.
    var sendHandler: ((Any.Type, APIEndpoint) throws -> Any)?

    /// Canned result for `sendVoid`.
    var sendVoidHandler: ((APIEndpoint) throws -> Void)?

    /// Canned raw result for `sendRaw`: the body with its HTTP status code.
    var sendRawHandler: ((APIEndpoint) throws -> (data: Data, statusCode: Int))?

    /// Number of times `sendRaw` was called.
    private(set) var sendRawCallCount = 0

    // MARK: - Recording

    private func record(_ endpoint: APIEndpoint) {
        lock.lock()
        _received.append(
            Received(
                method: endpoint.method,
                path: endpoint.path,
                requiresAuth: endpoint.requiresAuth,
                body: endpoint.body,
                customBearer: endpoint.customBearer
            )
        )
        lock.unlock()
    }

    // MARK: - APISending

    func send<T: Decodable & Sendable>(_ endpoint: APIEndpoint, as: T.Type) async throws -> T {
        record(endpoint)
        sendCallCount += 1

        if let throwError {
            if let apiError = throwError as? APIError {
                throw apiError
            }
            throw APIError.transport(underlying: String(describing: throwError))
        }

        do {
            guard let result = try sendHandler?(T.self, endpoint) as? T else {
                throw APIError.unexpected
            }
            return result
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(underlying: String(describing: error))
        }
    }

    func sendVoid(_ endpoint: APIEndpoint) async throws {
        record(endpoint)
        sendVoidCallCount += 1

        if let throwError {
            if let apiError = throwError as? APIError {
                throw apiError
            }
            throw APIError.transport(underlying: String(describing: throwError))
        }

        do {
            try sendVoidHandler?(endpoint)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(underlying: String(describing: error))
        }
    }

    func sendRaw(_ endpoint: APIEndpoint) async throws -> (data: Data, statusCode: Int) {
        record(endpoint)
        sendRawCallCount += 1

        if let throwError {
            if let apiError = throwError as? APIError {
                throw apiError
            }
            throw APIError.transport(underlying: String(describing: throwError))
        }

        do {
            guard let result = try sendRawHandler?(endpoint) else {
                throw APIError.unexpected
            }
            return result
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(underlying: String(describing: error))
        }
    }

}
