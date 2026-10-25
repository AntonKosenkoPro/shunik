import Foundation

/// Network client for the auth API.
///
/// Builds `URLRequest`s from `APIEndpoint`s against `baseURL`, attaches a
/// Bearer token from `accessTokenProvider` when `requiresAuth`, attaches the
/// stable device identifier from `deviceIdProvider` as `X-Device-Id`
/// (device-sessions spec), decodes either the success body or the uniform
/// error envelope, maps offline via `URLError.notConnectedToInternet`, and
/// on 401 transparently refreshes once via `refreshHandler` and retries the
/// request.
actor APIClient: APISending {
    let baseURL: URL
    let session: URLSession
    let decoder: JSONDecoder
    let encoder: JSONEncoder

    /// Returns the current access token, or `nil` if none. Called lazily per
    /// request that requires auth. Injected so production wires Keychain and
    /// tests wire a stub.
    private let accessTokenProvider: @Sendable () async -> String?
    /// Performs a refresh using the stored refresh token. Returns the new
    /// access token on success, throws on failure. `nil` disables refresh.
    private let refreshHandler: (@Sendable () async throws -> String)?
    /// Returns the stable device identifier sent as `X-Device-Id`. The auth
    /// backend 400s any session-carrying request without it, so a `nil`
    /// provider is only sensible in graphs that never hit the auth API
    /// (e.g. the UI-testing stub).
    private let deviceIdProvider: (@Sendable () async -> String)?

    init(
        baseURL: URL,
        session: URLSession,
        accessTokenProvider: @escaping @Sendable () async -> String? = { nil },
        refreshHandler: (@Sendable () async throws -> String)? = nil,
        deviceIdProvider: (@Sendable () async -> String)? = nil,
        decoder: JSONDecoder = APIClient.defaultDecoder(),
        encoder: JSONEncoder = APIClient.defaultEncoder()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.accessTokenProvider = accessTokenProvider
        self.refreshHandler = refreshHandler
        self.deviceIdProvider = deviceIdProvider
        self.decoder = decoder
        self.encoder = encoder
    }

    static func defaultDecoder() -> JSONDecoder {
        JSONDecoder() // snake_case handled via explicit CodingKeys
    }

    static func defaultEncoder() -> JSONEncoder {
        JSONEncoder() // snake_case handled via explicit CodingKeys
    }

    // MARK: - Public

    /// Sends an endpoint and decodes the success body as `T`.
    func send<T: Decodable & Sendable>(_ endpoint: APIEndpoint, as: T.Type) async throws -> T {
        let data = try await requestData(endpoint, allowRetry: true)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(underlying: String(describing: error))
        }
    }

    /// Sends an endpoint expecting an empty success body (204).
    func sendVoid(_ endpoint: APIEndpoint) async throws {
        let data = try await requestData(endpoint, allowRetry: true)
        if data.isEmpty { return }
        if let str = String(data: data, encoding: .utf8),
           str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
    }

    /// Sends an endpoint and returns the raw body with its HTTP status code.
    /// Non-2xx responses throw the same envelope errors as `send`. Requests
    /// carrying `customBearer` never trigger the refresh-and-retry path: a
    /// status credential is not a session and must never mint one.
    func sendRaw(_ endpoint: APIEndpoint) async throws -> (data: Data, statusCode: Int) {
        let request = try await makeRequest(endpoint)
        do {
            return try await executeRaw(request)
        } catch APIError.unauthorized where endpoint.requiresAuth && endpoint.customBearer == nil {
            return try await refreshAndRetryRaw(endpoint)
        } catch APIError.authenticationRejected where endpoint.requiresAuth && endpoint.customBearer == nil {
            return try await refreshAndRetryRaw(endpoint)
        }
    }

    // MARK: - Internals

    private func requestData(_ endpoint: APIEndpoint, allowRetry: Bool) async throws -> Data {
        let request = try await makeRequest(endpoint)
        do {
            return try await execute(request)
        } catch APIError.unauthorized where allowRetry && endpoint.requiresAuth && endpoint.customBearer == nil {
            return try await refreshAndRetry(endpoint)
        } catch APIError.authenticationRejected where allowRetry && endpoint.requiresAuth && endpoint.customBearer == nil {
            return try await refreshAndRetry(endpoint)
        }
    }

    /// The single refresh owner for a protected request: runs the refresh
    /// handler once and retries the request with the new token. Refresh
    /// failures surface with their outcome preserved (revocation codes,
    /// conflicts, transport/decoding/storage) so callers can tell a
    /// conclusive rejection from an ambiguous failure; only a superseded
    /// (cancelled) refresh propagates as-is.
    private func refreshAndRetry(_ endpoint: APIEndpoint) async throws -> Data {
        guard let refreshHandler else { throw APIError.unauthorized }
        let newToken: String
        do {
            newToken = try await refreshHandler()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError {
            // Preserve offline and transport failures so callers do not
            // sign out merely because a refresh could not reach the API.
            throw error
        } catch {
            throw APIError.unauthorized
        }
        guard !newToken.isEmpty else { throw APIError.unauthorized }
        let retryRequest = try await makeRequest(endpoint, overrideToken: newToken)
        return try await execute(retryRequest)
    }

    /// The raw variant of `refreshAndRetry`: same single-refresh ownership,
    /// preserving the HTTP status code for status-sensitive endpoints.
    private func refreshAndRetryRaw(_ endpoint: APIEndpoint) async throws -> (data: Data, statusCode: Int) {
        guard let refreshHandler else { throw APIError.unauthorized }
        let newToken: String
        do {
            newToken = try await refreshHandler()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError {
            // Preserve offline and transport failures so callers do not
            // sign out merely because a refresh could not reach the API.
            throw error
        } catch {
            throw APIError.unauthorized
        }
        guard !newToken.isEmpty else { throw APIError.unauthorized }
        let retryRequest = try await makeRequest(endpoint, overrideToken: newToken)
        return try await executeRaw(retryRequest)
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        try await executeRaw(request).data
    }

    /// Executes one request round-trip, returning the body with its status.
    /// `interpret` throws the envelope errors for non-2xx; transport mapping
    /// matches `execute` exactly.
    private func executeRaw(_ request: URLRequest) async throws -> (data: Data, statusCode: Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return try interpret(data: data, response: response)
        } catch let urlError as URLError {
            throw mapURLError(urlError)
        } catch APIError.unauthorized {
            throw APIError.unauthorized
        } catch let apiError as APIError {
            throw apiError
        } catch {
            throw APIError.transport(underlying: String(describing: error))
        }
    }

    private func interpret(data: Data, response: URLResponse) throws -> (data: Data, statusCode: Int) {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.unexpected
        }
        switch http.statusCode {
        case 200...299:
            return (data, http.statusCode)
        case 401:
            // Surface the structured rejection (invalid_refresh, token_reuse,
            // refresh_expired, ...) instead of collapsing every 401 into one
            // undifferentiated signal. A missing/undecodable envelope keeps
            // the legacy bare form.
            if !data.isEmpty,
               let env = try? decoder.decode(ErrorEnvelope.self, from: data) {
                throw APIError.authenticationRejected(
                    code: env.error.code,
                    message: env.error.message,
                    details: env.detailsAsStringMap
                )
            }
            throw APIError.unauthorized
        default:
            if !data.isEmpty,
               let env = try? decoder.decode(ErrorEnvelope.self, from: data) {
                throw APIError.server(
                    code: env.error.code,
                    message: env.error.message,
                    details: env.detailsAsStringMap
                )
            }
            throw APIError.server(
                code: "http_\(http.statusCode)",
                message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            )
        }
    }

    private func mapURLError(_ error: URLError) -> APIError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff, .timedOut:
            return .offline
        default:
            return .transport(underlying: error.localizedDescription)
        }
    }

    private func makeRequest(_ endpoint: APIEndpoint, overrideToken: String? = nil) async throws -> URLRequest {
        let base = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        guard let url = URL(string: base + endpoint.path) else {
            throw APIError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let deviceId = await deviceIdProvider?(), !deviceId.isEmpty {
            request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        }
        if let body = endpoint.body {
            request.httpBody = body
        }
        // Explicit Bearer scheme wins over the session token: a status
        // credential (or any future dedicated capability) authenticates its
        // own request and must never mint or trigger a session refresh. The
        // two are never combined — customBearer present means the session
        // token is not sent.
        if let custom = endpoint.customBearer, !custom.isEmpty {
            request.setValue("Bearer \(custom)", forHTTPHeaderField: "Authorization")
        } else if endpoint.requiresAuth {
            let token: String?
            if let overrideToken { token = overrideToken } else { token = await accessTokenProvider() }
            if let token, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }
}

/// Uniform error envelope decoded from any non-2xx response.
struct ErrorEnvelope: Decodable, Sendable {
    struct Body: Decodable, Sendable {
        let code: String
        let message: String
        let details: DetailsEnvelope?
    }
    let error: Body

    var detailsAsStringMap: [String: String] {
        error.details?.asStringMap ?? [:]
    }
}

/// `details` is either a dict or an array in the contract. We accept both,
/// lossy, and expose the dict form.
struct DetailsEnvelope: Decodable, Sendable {
    let raw: AnyCodable

    init(from decoder: Decoder) throws {
        self.raw = try AnyCodable(from: decoder)
    }

    var asStringMap: [String: String] {
        raw.stringDictionary
    }
}

/// Codable, Sendable representation for opaque JSON details payloads.
/// The contract's `details` is either an object or (rarely) a null/string;
/// numeric/bool/array values are never produced by the backend, so those cases
/// are not represented here.
enum AnyCodable: Codable, Sendable {
    case null
    case string(String)
    case object([String: AnyCodable])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: AnyCodable].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .string(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    var stringDictionary: [String: String] {
        guard case let .object(values) = self else { return [:] }
        return values.compactMapValues { value in
            guard case let .string(string) = value else { return nil }
            return string
        }
    }
}
