import Foundation

/// Central duration formatting (one implementation per grammar; the former
/// `TimeFormatter` clock, `HistoryViewModel` natural-language, and
/// `SyncRelativeTime` sync-age call sites all resolve here with no behavior
/// change — the legacy entry points forward to these).
enum DurationFormatting {
    /// Clock duration: `HH:MM:SS` past the hour, else `MM:SS`, zero-padded.
    /// (Timer readout, compact timer.)
    static func clock(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        let paddedMinutes = String(format: "%02d", minutes)
        let paddedSeconds = String(format: "%02d", seconds)

        if hours > 0 {
            return "\(hours):\(paddedMinutes):\(paddedSeconds)"
        }
        return "\(paddedMinutes):\(paddedSeconds)"
    }

    /// Natural-language duration in the given locale (`33s`, `1m 20s`,
    /// `1h 12m`, `1d 12h` in English; locale-correct abbreviations and
    /// plurals elsewhere, e.g. `1 ч 12 мин` in Russian) (History D5). The
    /// grammar — which tiers appear — is fixed here; Foundation owns the
    /// unit words.
    static func natural(_ seconds: Int, locale: Locale = .current) -> String {
        let total = max(0, seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60

        if days > 0 {
            return hours > 0
                ? "\(unit(days, .day, locale)) \(unit(hours, .hour, locale))"
                : unit(days, .day, locale)
        }
        if hours > 0 {
            return minutes > 0
                ? "\(unit(hours, .hour, locale)) \(unit(minutes, .minute, locale))"
                : unit(hours, .hour, locale)
        }
        if minutes > 0 {
            return secs > 0
                ? "\(unit(minutes, .minute, locale)) \(unit(secs, .second, locale))"
                : unit(minutes, .minute, locale)
        }
        return unit(secs, .second, locale)
    }

    /// Locale-aware single-unit words backing `natural` (one tiny
    /// `DateComponentsFormatter` each: a whole-string formatter cannot
    /// reproduce the two-tier grammar). The calendar is fixed to Gregorian —
    /// unit words do not depend on the calendar system — with the caller's
    /// locale applied to it.
    static func unit(_ value: Int, _ component: Calendar.Component, _ locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.calendar = calendar
        var components = DateComponents()
        switch component {
        case .day:
            components.day = value
            formatter.allowedUnits = [.day]
        case .hour:
            components.hour = value
            formatter.allowedUnits = [.hour]
        case .minute:
            components.minute = value
            formatter.allowedUnits = [.minute]
        default:
            components.second = value
            formatter.allowedUnits = [.second]
        }
        return formatter.string(from: components) ?? "\(value)"
    }

    // MARK: - Sync age (Profile "Last synced" row)

    /// Maps elapsed seconds to a bucket. No `Date()` inside — callers pass
    /// `now.timeIntervalSince(date)`; negative (future) clamps to `.justNow`.
    static func syncBucket(elapsed: TimeInterval) -> SyncAgeBucket {
        guard elapsed >= 60 else { return .justNow }
        let minutes = Int(elapsed / 60)
        guard minutes >= 60 else { return .minutes(minutes) }
        let hours = minutes / 60
        guard hours >= 24 else { return .hours(hours) }
        return .days(hours / 24)
    }

    /// Localized quantity for a bucket ("59 minutes", "5 минут").
    /// Restricted `allowedUnits` + `maximumUnitCount = 1` truncate and never
    /// escalate units; the numeric fallback is unreachable defense (exact
    /// multiples of the unit always format).
    static func syncQuantity(for bucket: SyncAgeBucket, locale: Locale = .current) -> String {
        let formatter = DateComponentsFormatter()
        formatter.maximumUnitCount = 1
        formatter.unitsStyle = .full
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        switch bucket {
        case .justNow:
            return ""
        case let .minutes(count):
            formatter.allowedUnits = [.minute]
            return formatter.string(from: TimeInterval(count * 60)) ?? "\(count)"
        case let .hours(count):
            formatter.allowedUnits = [.hour]
            return formatter.string(from: TimeInterval(count * 3600)) ?? "\(count)"
        case let .days(count):
            formatter.allowedUnits = [.day]
            return formatter.string(from: TimeInterval(count * 86400)) ?? "\(count)"
        }
    }

    /// Age subtitle for the idle row ("1 minute ago", "Меньше минуты назад").
    /// Glue strings are parameters (view passes L10n, tests pass literals) so
    /// composition is pinnable in any locale.
    static func syncSubtitle(
        since date: Date,
        now: Date,
        ago: String,
        justNow: String,
        locale: Locale = .current
    ) -> String {
        let bucket = syncBucket(elapsed: now.timeIntervalSince(date))
        guard case .justNow = bucket else {
            return String(format: ago, syncQuantity(for: bucket, locale: locale))
        }
        return justNow
    }
}
