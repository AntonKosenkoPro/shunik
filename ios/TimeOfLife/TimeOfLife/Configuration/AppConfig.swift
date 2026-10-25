import Foundation
import OSLog

/// App-wide configuration sourced from `Info.plist` / the per-configuration xcconfig.
///
/// `API_BASE_URL` is injected into `Info.plist` via `Config.Debug.xcconfig`
/// (dev: `http://127.0.0.1:8080`) or `Config.Release.xcconfig`
/// (prod: `https://shunik-api.antonkosenko.pro`) and read here.
enum AppConfig {
    private static let defaultBaseURL = URL(string: "http://127.0.0.1:8080")!

    /// Base URL for the API (no trailing slash). Defaults to the dev backend.
    static let baseURL: URL = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String
        return parseBaseURL(raw)
    }()

    /// Parses an API base URL string, falling back to the dev default if the
    /// input is missing or malformed. Internal so tests can exercise it.
    static func parseBaseURL(_ raw: String?) -> URL {
        let trimmed = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        guard let trimmed, !trimmed.isEmpty else {
            logWarning("API_BASE_URL missing or empty in Info.plist; using default")
            return defaultBaseURL
        }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme, !scheme.isEmpty,
              let host = url.host, !host.isEmpty else {
            logWarning("API_BASE_URL '\(trimmed)' is malformed; using default")
            return defaultBaseURL
        }

        // Remove trailing slash so APIClient can append endpoint.path safely.
        let normalized = trimmed.hasSuffix("/")
            ? String(trimmed.dropLast())
            : trimmed

        guard let normalizedURL = URL(string: normalized) else {
            logWarning("API_BASE_URL '\(trimmed)' could not be normalized; using default")
            return defaultBaseURL
        }

        logInfo("API_BASE_URL resolved to \(normalizedURL.absoluteString)")
        return normalizedURL
    }

    private static func logWarning(_ message: String) {
        Logger.appConfig.warning("\(message)")
    }

    private static func logInfo(_ message: String) {
        Logger.appConfig.info("\(message)")
    }
}

private extension Logger {
    static let appConfig = Logger(subsystem: "com.antonkosenko.shunik", category: "AppConfig")
}
