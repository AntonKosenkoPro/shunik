import SwiftUI

/// Shared chip-group viewport contract (inline-category-creation):
/// `TagSelector` and `RecentActivitiesChips` clamp to the same fixed row
/// budget with internal scroll, hug smaller content (no dead space), and
/// fade the same edge-aware hairline dividers. Clamp math and edge
/// derivation are shared so the two groups behave identically.
enum ChipViewport {
    /// Visible-row clamp: four full rows. Fixed points (not available
    /// slack): the host is an outer `ScrollView` with unbounded offers, so
    /// a flexible cap would claim the full content height and slide under
    /// the tab bar.
    static let maxVisibleRows: CGFloat = 4
    /// Floor when shrinking into a finite budget (compact phones): at least
    /// one full row stays visible; the rest scrolls internally.
    static let minVisibleRows: CGFloat = 1
    /// Extra viewport slack so the lowest row's hairline border never clips
    /// at the exact 4-row cut. Shared by both chip groups: implemented as
    /// vertical content inset (`borderBleed / 2` top + bottom) inside the
    /// `ScrollView`, not as frame slack alone: when all rows fit, `fixedSize`
    /// hugs the content so a taller `maxHeight` cap never materializes —
    /// only inset content carries clearance. Covers the centered 1 pt chip
    /// stroke overhang (0.5 pt per side) with rounding headroom.
    static let borderBleed: CGFloat = 2
    /// Scroll-edge state driving the dividers: the top divider shows only
    /// once content scrolled under it, the bottom one only while content
    /// remains below. Both stay hidden when everything fits.
    struct Edges: Equatable {
        var atTop = true
        var atEnd = true
    }

    /// Viewport height for the row clamp: full rows plus inter-row gaps.
    /// Pure and `nonisolated` so the clamp math is unit-testable.
    nonisolated static func clampedHeight(rowHeight: CGFloat, spacing: CGFloat) -> CGFloat {
        maxVisibleRows * rowHeight + (ceil(maxVisibleRows) - 1) * spacing
    }

    /// Fixed viewport cap: the 4-row clamp plus the border bleed. Used when
    /// no finite budget is measured yet (first paint, previews, entry forms)
    /// and on viewports tall enough to fit it — large-device layout is
    /// unchanged.
    nonisolated static func maxHeight(rowHeight: CGFloat, spacing: CGFloat) -> CGFloat {
        clampedHeight(rowHeight: rowHeight, spacing: spacing) + borderBleed
    }

    /// Adaptive viewport: the fixed cap shrunk into a finite host budget.
    /// The budget is measured outside the outer `ScrollView` (whose offers
    /// are unbounded), so `min` against it is meaningful. A nil budget keeps
    /// the fixed cap; a budget below one full row floors at one row plus
    /// bleed so the viewport never collapses — overflow always scrolls
    /// internally instead of pushing siblings or the tab bar.
    nonisolated static func viewportHeight(
        rowHeight: CGFloat,
        spacing: CGFloat,
        availableHeight: CGFloat?
    ) -> CGFloat {
        let maxH = maxHeight(rowHeight: rowHeight, spacing: spacing)
        guard let availableHeight else { return maxH }
        let floor = minVisibleRows * rowHeight + borderBleed
        return min(maxH, max(availableHeight, floor))
    }

    /// Derives the edge state from scroll geometry. Pure and `nonisolated`
    /// so the divider contract is unit-testable. The half-point tolerance
    /// absorbs float noise at the exact edges.
    nonisolated static func edges(
        offsetY: CGFloat,
        containerHeight: CGFloat,
        contentHeight: CGFloat
    ) -> Edges {
        Edges(
            atTop: offsetY <= 0.5,
            atEnd: offsetY + containerHeight >= contentHeight - 0.5
        )
    }
}
