import SwiftUI

/// The Track Recents chip flow (timer-capture-experience spec,
/// design D5). Presents up to twelve most-recently-used exact entry texts as
/// a wrapping flow of chips with 44 pt tap targets; the flow hugs its rows
/// up to a three-row budget and overflow scrolls internally on the chip
/// axis, so the Track page footprint never grows for Recents overflow.
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

    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize

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

    /// Visible chip-area budget: three chip rows at `minTapArea` with
    /// `spacingSmall` gaps (the common six-chip footprint). Order matters:
    /// `maxHeight` sits INSIDE `fixedSize`, so the chain reports
    /// `min(content, budget)` — hugging rows up to the budget, scrolling
    /// beyond it. Reversed (fixedSize inside maxHeight) the flexible frame
    /// would report the full proposal regardless of content: dead space
    /// for few chips, unclipped spillover instead of scroll for many.
    private static let maxVisibleHeight: CGFloat = 3 * Theme.minTapArea + 2 * Theme.spacingSmall

    var body: some View {
        ScrollView(.vertical) {
            flow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: Self.maxVisibleHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The chip flow: hugged by `fixedSize` up to the budget above.
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
                .font(.subheadline.weight(.medium))
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
