import Foundation

/// Formats `TimeInterval` values into user-facing duration strings.
/// Clock grammar lives in `DurationFormatting`; this entry point forwards
/// so existing call sites keep compiling unchanged.
enum TimeFormatter {
    /// Formats a duration as `HH:MM:SS` when an hour or more has elapsed,
    /// otherwise `MM:SS`. Always zero-pads each segment.
    static func formattedDuration(_ interval: TimeInterval) -> String {
        DurationFormatting.clock(interval)
    }
}
