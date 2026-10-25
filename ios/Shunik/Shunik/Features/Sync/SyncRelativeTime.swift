import Foundation

/// Minute-bucketed age of the last sync for Profile's "Last synced" row
/// (fix-sync-status-row, sync-client spec).
///
/// Buckets: under a minute, whole minutes 1–59, whole hours 1–23, whole days
/// with no upper cap (never weeks/months/years). A future timestamp (clock
/// skew) renders as `.justNow` — never future tense.
///
/// Quantity words ("37 minutes", "2 минуты") come from the system quantity
/// formatter, which owns pluralization in every locale; only connective
/// words live in L10n. The helper takes elapsed seconds and glue strings, so
/// it is locale-pure and unit-testable without clocks or bundles.
///
/// Implementation lives in `DurationFormatting` (one duration-formatting
/// home for clock, natural-language, and sync-age grammars); this enum
/// forwards so existing call sites keep compiling unchanged.
enum SyncAgeBucket: Equatable {
    case justNow
    case minutes(Int)
    case hours(Int)
    case days(Int)
}

enum SyncRelativeTime {
    /// Maps elapsed seconds to a bucket. No `Date()` inside — callers pass
    /// `now.timeIntervalSince(date)`; negative (future) clamps to `.justNow`.
    static func bucket(elapsed: TimeInterval) -> SyncAgeBucket {
        DurationFormatting.syncBucket(elapsed: elapsed)
    }

    /// Localized quantity for a bucket ("59 minutes", "5 минут").
    /// Restricted `allowedUnits` + `maximumUnitCount = 1` truncate and never
    /// escalate units; the numeric fallback is unreachable defense (exact
    /// multiples of the unit always format).
    static func quantity(for bucket: SyncAgeBucket, locale: Locale = .current) -> String {
        DurationFormatting.syncQuantity(for: bucket, locale: locale)
    }

    /// Age subtitle for the idle row ("1 minute ago", "Меньше минуты назад").
    /// Glue strings are parameters (view passes L10n, tests pass literals) so
    /// composition is pinnable in any locale.
    static func subtitle(
        since date: Date,
        now: Date,
        ago: String,
        justNow: String,
        locale: Locale = .current
    ) -> String {
        DurationFormatting.syncSubtitle(since: date, now: now, ago: ago, justNow: justNow, locale: locale)
    }
}
