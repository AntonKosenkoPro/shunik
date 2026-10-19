import SwiftUI

/// The Track Recents chip flow (timer-capture-experience spec,
/// design D5). Presents up to twelve most-recently-used exact entry texts as
/// a wrapping flow of chips with 44 pt tap targets; the flow hugs its rows
/// up to a four-row budget measured against the host, and overflow scrolls
/// internally on the chip axis, so the Track page footprint never grows for
/// Recents overflow and compact phones shrink the viewport instead of
/// sliding under the tab bar.
///
/// Each chip shows the icon of the first category of that exact text's
/// newest committed entry (first by stored position, resolved through the
/// id-to-Category map); texts without categories render name-only. The
/// prepared text's chip keeps its icon and switches to a filled accent
/// presentation (accent background, on-accent text, accent border) — the
/// same non-color-only selected treatment as `TagSelector` (fill + contrast,
/// no checkmark, so chips stay compact). Chips wrap via the shared
/// `FlowLayout` with equal `Theme.spacingSmall` gaps.
struct RecentActivitiesChips: View {
    let recents: [ExactName]
    let categories: [String: Category]
    let selectedText: String?
    let onSelect: (ExactName) -> Void
    /// Finite host budget for the viewport (Track): the host viewport minus
    /// the measured siblings, gaps, and tab-bar margin (see `TrackContent`).
    /// Same adaptive contract as `TagSelector` — `min(4-row cap, budget)`
    /// floored at one row; nil keeps the fixed 4-row cap.
    let availableHeight: CGFloat?

    init(
        recents: [ExactName],
        categories: [String: Category],
        selectedText: String?,
        availableHeight: CGFloat? = nil,
        onSelect: @escaping (ExactName) -> Void
    ) {
        self.recents = recents
        self.categories = categories
        self.selectedText = selectedText
        self.availableHeight = availableHeight
        self.onSelect = onSelect
    }

    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize

    /// Scroll-edge state for the viewport dividers (shared `ChipViewport`
    /// math — same clamp and fade contract as the tag selector).
    @State private var edges = ChipViewport.Edges()

    /// The capped, most-recently-used-first slice (the store already sorts
    /// by the text's newest `started_at`; the cap is
    /// `TrackViewModel.recentsLimit`).
    private var capped: [ExactName] { Self.recents(from: recents) }

    /// The capped, most-recently-used-first slice of the given recents.
    /// Pure (no view state), so `nonisolated` like `EntryRow.accessibilityLabel`.
    nonisolated static func recents(
        from recents: [ExactName],
        limit: Int = TrackViewModel.recentsLimit
    ) -> [ExactName] {
        Array(recents.prefix(limit))
    }

    /// Chip row height: subheadline line height at the environment's Dynamic
    /// Type size plus uniform padding, floored at the 44 pt target so the
    /// clamp holds under Dynamic Type.
    private var chipRowHeight: CGFloat {
        let lineHeight = UIFont.preferredFont(
            forTextStyle: .subheadline,
            compatibleWith: sizeTrait
        ).lineHeight
        return max(Theme.minTapArea, lineHeight + 2 * 12)
    }

    var body: some View {
        // Zero-layout edge hairlines: overlays on the ScrollView's outer
        // frame (not VStack siblings, never scrolled content), so the
        // viewport total stays within the measured host budget as the top
        // hairline fades in — top fades in once chips scroll under it,
        // bottom fades out at the content end, both hidden when everything
        // fits. The viewport hugs content up to the measured host budget
        // (four rows max) and scrolls internally beyond it — never pushing
        // siblings or the page.
        ScrollView(.vertical) {
            flow
                // Content inset carries the border clearance (same as
                // `TagSelector`): when the catalog fits, `fixedSize` hugs
                // the content height, so frame slack alone never
                // materializes. 1 pt top/bottom keeps the chip strokes
                // fully visible.
                .padding(.vertical, ChipViewport.borderBleed / 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: ChipViewport.viewportHeight(
            rowHeight: chipRowHeight,
            spacing: Theme.spacingSmall,
            availableHeight: availableHeight
        ))
        .fixedSize(horizontal: false, vertical: true)
        .onScrollGeometryChange(for: ChipViewport.Edges.self, of: { geometry in
            ChipViewport.edges(
                offsetY: geometry.contentOffset.y,
                containerHeight: geometry.containerSize.height,
                contentHeight: geometry.contentSize.height
            )
        }, action: { _, new in
            edges = new
        })
        // Overlays add zero layout height and ignore hits, so divider
        // visibility never changes geometry or intercepts chip taps/scroll.
        .overlay(alignment: .top) {
            if !edges.atTop {
                Divider().background(Theme.hairline)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if !edges.atEnd {
                Divider().background(Theme.hairline)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: edges)
    }

    /// The chip flow: hugged by `fixedSize` up to the available slack above.
    private var flow: some View {
        FlowLayout(spacing: Theme.spacingSmall) {
            ForEach(capped) { recent in
                chip(recent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A trait collection matching the SwiftUI environment's effective
    /// Dynamic Type size, so the icon glyph scales with rendering
    /// (also under a `.dynamicTypeSize` environment override,
    /// which `UIFont.preferredFont` alone would not reflect).
    private var sizeTrait: UITraitCollection {
        UITraitCollection(preferredContentSizeCategory: dynamicTypeSize.uiContentSizeCategory)
    }

    /// Icon glyph size at the effective size.
    private var symbolFontSize: CGFloat {
        let metrics = UIFontMetrics(forTextStyle: .subheadline)
        return metrics.scaledFont(
            for: UIFont.systemFont(ofSize: 14),
            compatibleWith: sizeTrait
        ).pointSize
    }

    /// Fixed icon slot so wide SF Symbols stay fully visible and the
    /// measured chip width is exact.
    private var symbolSlotSize: CGFloat {
        DynamicTypeMetrics.symbolSlotSize(
            basePointSize: 14,
            textStyle: .subheadline,
            dynamicTypeSize: dynamicTypeSize
        )
    }

    @ViewBuilder
    private func chip(_ recent: ExactName) -> some View {
        let isSelected = selectedText == recent.text
        Button {
            onSelect(recent)
        } label: {
            chipLabel(recent: recent, isSelected: isSelected)
        }
        .accessibilityLabel(String(format: L10n.timerSelectActivity.text, recent.text))
        .accessibilityValue(isSelected ? L10n.undoSelected.text : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("TimerSuggestion(\(recent.text))")
    }

    private func chipLabel(recent: ExactName, isSelected: Bool) -> some View {
        HStack(spacing: Theme.spacingExtraSmall) {
            if let categoryID = recent.firstCategoryID,
               let category = categories[categoryID] {
                Image(systemName: CatalogIcon(validated: category.icon).displaySymbol)
                    .font(.system(size: symbolFontSize))
                    .frame(width: symbolSlotSize)
                    .accessibilityHidden(true)
            }
            Text(recent.text)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(isSelected ? Theme.textOnAccent : Theme.textPrimary)
        .padding(.horizontal, Theme.spacingMedium)
        .padding(.vertical, 12)
        .frame(minHeight: Theme.minTapArea)
        .background(isSelected ? Theme.accentPrimary : Theme.backgroundSecondary)
        .clipShape(Capsule())
        .overlay {
            Capsule().stroke(
                isSelected ? Theme.accentPrimary : Theme.hairline,
                lineWidth: 0.7
            )
        }
    }
}

extension DynamicTypeSize {
    /// The `UIContentSizeCategory` equivalent of the environment's Dynamic
    /// Type size, used to build a measurement trait collection.
    var uiContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}

#if DEBUG
#Preview("Recents — Icons, selected, wrapped") {
    let categories = [
        Category(id: "c1", name: "Work", icon: "laptopcomputer"),
        Category(id: "c2", name: "Study", icon: "book"),
        Category(id: "c3", name: "Sport", icon: "figure.run")
    ]
    let recents = [
        ExactName(text: "Deep work", categoryIDs: ["c1"], firstCategoryID: "c1"),
        ExactName(text: "Reading", categoryIDs: ["c2"], firstCategoryID: "c2"),
        ExactName(text: "Gym session", categoryIDs: ["c3"], firstCategoryID: "c3"),
        ExactName(text: "Planning", categoryIDs: [], firstCategoryID: nil),
        ExactName(text: "A very long entry name that truncates", categoryIDs: ["c1"], firstCategoryID: "c1")
    ]
    return RecentActivitiesChips(
        recents: recents,
        categories: Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) }),
        selectedText: "Deep work"
    ) { _ in }
    .padding()
    .background(Theme.backgroundPrimary)
}

#Preview("Recents — Twelve, overflow scrolls internally") {
    let categories = [
        Category(id: "c1", name: "Work", icon: "laptopcomputer"),
        Category(id: "c2", name: "Study", icon: "book"),
        Category(id: "c3", name: "Sport", icon: "figure.run")
    ]
    let recents = (0..<12).map { index in
        let categorized = index < 6
        return ExactName(
            text: "Entry number \(index)",
            categoryIDs: categorized ? ["c1"] : [],
            firstCategoryID: categorized ? ["c1", "c2", "c3"][index / 2] : nil
        )
    }
    return RecentActivitiesChips(
        recents: recents,
        categories: Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) }),
        selectedText: "Entry number 0"
    ) { _ in }
    .padding()
    .background(Theme.backgroundPrimary)
}

#Preview("Recents — Empty") {
    RecentActivitiesChips(
        recents: [],
        categories: [:],
        selectedText: nil
    ) { _ in }
    .padding()
    .background(Theme.backgroundPrimary)
}
#endif
