import ActivityKit
import Foundation

/// ActivityKit attributes for the running-timer Live Activity
/// (live-activities spec: "Live Activity follows the running timer").
///
/// Lives in the shared `LifioLiveActivityCore` framework linked by BOTH the
/// app target (which requests/ends the activity) and the widget extension
/// (which renders it and ends it from the Stop intent) — a single module,
/// so ActivityKit matches both sides' `Activity<Attributes>.activities`.
/// Depends only on Foundation + ActivityKit, never on app modules
/// (`LocalStore`, `Theme`, `L10n`). Data only: all copy lives in the
/// extension's views (localized in 3.4). Extension-safe: no UIApplication.
public struct TimerActivityAttributes: ActivityAttributes, Equatable {
    /// The exact entry text, verbatim. Identity is trimmed exact text
    /// (case-sensitive: `Gym` ≠ `GYM`) — faces truncate to one line but
    /// never normalize.
    public var entryText: String
    /// SF Symbol name of the first-position category icon, or `"timer"`
    /// when the run has no categories (the recents-chip rule: icon or
    /// nothing — never names).
    public var iconSymbol: String

    public init(entryText: String, iconSymbol: String) {
        self.entryText = entryText
        self.iconSymbol = iconSymbol
    }

    /// The live slice. Faces tick from `startedAt` via the system's
    /// `Text(timerInterval:)` — no per-second `update()` calls (D1).
    /// Category chips refresh on mid-run retag via a targeted `update()`
    /// — retag-only frequency, never a loop.
    public struct ContentState: Codable, Hashable {
        /// When the run started.
        public var startedAt: Date
        /// Final duration for the Saved end-card; nil while running.
        public var savedDurationSeconds: Int?
        /// Ordered chips for the draft's categories at the last
        /// start/retag; empty when the run has no categories. Names are
        /// user data (never localized); icon symbols arrive pre-validated
        /// from the app, so the extension never validates.
        public var categoryChips: [LiveCategoryChip]

        public init(startedAt: Date, savedDurationSeconds: Int? = nil, categoryChips: [LiveCategoryChip] = []) {
            self.startedAt = startedAt
            self.savedDurationSeconds = savedDurationSeconds
            self.categoryChips = categoryChips
        }
    }
}

/// One category chip for the expanded Island bottom row. Top-level (not
/// nested) so the app, the widget, and tests all reference it bare. Lives
/// in the shared core so both sides share one shape.
public struct LiveCategoryChip: Codable, Hashable, Sendable {
    /// Display name, verbatim user data.
    public var name: String
    /// Pre-validated SF Symbol name (`CatalogIcon.displaySymbol` at request
    /// time).
    public var iconSymbol: String

    public init(name: String, iconSymbol: String) {
        self.name = name
        self.iconSymbol = iconSymbol
    }
}
