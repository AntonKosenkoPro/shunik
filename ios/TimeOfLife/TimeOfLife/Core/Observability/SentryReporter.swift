import Foundation
import OSLog
#if canImport(Sentry)
import Sentry
#endif

/// Crash + error reporting via Sentry (observability Stage 0).
///
/// - Enabled only when a DSN is present: `SENTRY_DSN` in `Info.plist`, fed by
///   the `SENTRY_DSN` build setting (per-config xcconfig, empty by default;
///   CI threads the `SENTRY_IOS_DSN` secret into it at archive time). Empty
///   or missing = the SDK never starts and every method below is a no-op.
/// - Privacy: the Sentry user carries the opaque account user-id ONLY — never
///   email, entry text, or category names. `sendDefaultPii` stays off and a
///   `beforeSend` scrub strips `email`/`username` if they ever get set.
/// - Scope: crash reporting + a breadcrumb trail for sync distress (SDK
///   default breadcrumbs are kept). No performance spans — Stage 1 owns spans,
///   so `tracesSampleRate` is deliberately left unset.
enum SentryReporter {
    private static let dsnInfoKey = "SENTRY_DSN"
    private static let logger = Logger(
        subsystem: "com.antonkosenko.shunik",
        category: "SentryReporter"
    )

    /// Starts the SDK when a DSN is configured; otherwise logs once and
    /// stays disabled. Safe to call on every launch (including UI-testing).
    static func startIfConfigured() {
        let raw = Bundle.main.object(forInfoDictionaryKey: dsnInfoKey) as? String
        guard let dsn = normalizeDSN(raw) else {
            logger.info("Sentry disabled: no DSN configured")
            return
        }
        #if canImport(Sentry)
        SentrySDK.start { options in
            options.dsn = dsn
            options.sendDefaultPii = false
            options.enableCrashHandler = true
            #if DEBUG
            options.environment = "development"
            #else
            options.environment = "production"
            #endif
            // Defense in depth for the no-PII rule: the reporter never sets
            // email/username, but if one ever slips in, drop it here rather
            // than shipping it. The user-id survives (opaque account id).
            options.beforeSend = { event in
                event.user?.email = nil
                event.user?.username = nil
                return event
            }
        }
        logger.info("Sentry started")
        #else
        logger.warning("Sentry DSN configured but the Sentry SDK is not linked")
        #endif
    }

    /// Binds Sentry events to the signed-in account's opaque user-id, or
    /// clears the user on sign-out (`nil`/empty clears). Call with
    /// `session.id` only — never email or anything user-entered.
    static func setUserID(_ userID: String?) {
        #if canImport(Sentry)
        if let userID, !userID.isEmpty {
            SentrySDK.setUser(User(userId: userID))
        } else {
            SentrySDK.setUser(nil)
        }
        #endif
    }

    /// Records a fixed-string sync-distress breadcrumb (cycle failures,
    /// store-open failures). `message` MUST be a static string — never
    /// interpolate entry text, category names, emails, or error details
    /// (server messages can echo user content).
    static func addSyncDistressBreadcrumb(_ message: String) {
        #if canImport(Sentry)
        let crumb = Breadcrumb(level: .warning, category: "sync")
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
        #endif
    }

    /// Normalizes a raw DSN plist value. Returns nil (disabled) for missing,
    /// empty, or unsubstituted `$(SENTRY_DSN)` values. Internal so tests can
    /// exercise it without a bundle.
    static func normalizeDSN(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("$(") else {
            return nil
        }
        return trimmed
    }
}
