import SwiftUI

/// Multi-select category chips for an activity (Design/COMPONENTS.md,
/// `TagSelector`). Wrapping flow of content-sized tappable chips with equal
/// `Theme.spacingSmall` gaps; toggling a chip adds/removes the category id
/// from the ordered selection (category-management D5/D6: zero-or-more,
/// selection order preserved). Categories are optional — the selector never
/// forces a selection.
///
/// Chips follow category-management D9: each chip is as wide as its content
/// (uniform `Theme.spacingChip` padding on all sides). The leading slot shows
/// the category icon when unselected, a `checkmark` for a lone selection, and
/// the 1-based selection ordinal when two or more chips are selected (both
/// 30% larger than `.caption`, scaling with Dynamic Type; two-digit ordinals
/// shrink to fit), no outline circles, and a 44 pt minimum tap target. The
/// slot keeps the measured chip width exact in every state, so toggling never
/// re-packs rows. Glyph changes fade in place. Chips wrap via the shared
/// `FlowLayout` with equal `Theme.spacingSmall` gaps.
struct TagSelector: View {
    let options: [Category]
    /// The selected ids in selection (tap) order; deselect-then-reselect
    /// appends at the end. The parent owns the order.
    let selected: [String]
    /// Called with the toggled category id; the parent owns the ordered
    /// selection.
    let onToggle: (String) -> Void
    let accessibilityId: String

    /// Fade duration for glyph transitions (select, deselect, renumber,
    /// checkmark↔ordinal swap).
    private static let glyphFadeDuration = 0.2

    /// The leading-slot content contract: icon when unselected, checkmark for
    /// a lone selection, else the 1-based selection ordinal. Pure so the
    /// ordinal derivation is unit-testable.
    enum ChipGlyph: Equatable {
        case icon
        case checkmark
        case ordinal(Int)
    }

    /// Resolves which glyph a chip shows for `id` within the ordered
    /// `selected` ids. Ordinals cap at 99 (a third digit is impossible).
    /// Pure and `nonisolated` so unit tests (and any nonisolated caller)
    /// can use it without an actor hop.
    nonisolated static func glyph(for id: String, in selected: [String]) -> ChipGlyph {
        guard let index = selected.firstIndex(of: id) else { return .icon }
        guard selected.count > 1 else { return .checkmark }
        return .ordinal(min(index + 1, 99))
    }

    var body: some View {
        FlowLayout(spacing: Theme.spacingSmall) {
            ForEach(options) { category in
                chip(category)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Icon and checkmark glyph size: 30% larger than the caption1 standard
    /// size (12 pt), scaled with Dynamic Type via `UIFontMetrics`.
    private var symbolFontSize: CGFloat {
        UIFontMetrics(forTextStyle: .caption1).scaledValue(for: 12 * 1.3)
    }

    /// Ordinal glyph size: full size for a single digit, shrunk for two
    /// digits so the pair fits the fixed slot.
    private func ordinalFontSize(position: Int) -> CGFloat {
        position < 10 ? symbolFontSize : symbolFontSize * 0.8
    }

    /// Fixed symbol slot: wide SF Symbols (e.g. `figure.run`) stay fully
    /// visible while the slot keeps the measured chip width exact. The same
    /// slot serves the icon, the checkmark, and the ordinal, so toggling
    /// never re-packs rows.
    private var symbolSlotSize: CGFloat {
        ceil(symbolFontSize * 1.5)
    }

    @ViewBuilder
    private func chip(_ category: Category) -> some View {
        let glyph = Self.glyph(for: category.id, in: selected)
        Button {
            onToggle(category.id)
        } label: {
            chipLabel(category: category, glyph: glyph)
        }
        .accessibilityLabel("\(L10n.manageCategoriesRowA11y.text), \(category.name)")
        .accessibilityValue(accessibilityValue(for: category.id))
        .accessibilityIdentifier("\(accessibilityId)Chip(\(category.id))")
    }

    /// VoiceOver value: not-selected when unselected, selected for a lone
    /// selection, and the ordinal position when two or more are selected.
    /// Derived from `glyph(for:in:)` so the spoken position always agrees
    /// with the visible numeral, including at the 99 cap.
    private func accessibilityValue(for id: String) -> String {
        switch Self.glyph(for: id, in: selected) {
        case .icon:
            return L10n.undoNotSelected.text
        case .checkmark:
            return L10n.undoSelected.text
        case let .ordinal(position):
            return String(format: L10n.undoSelectedPosition.text, locale: .current, position, selected.count)
        }
    }

    private func chipLabel(category: Category, glyph: ChipGlyph) -> some View {
        HStack(spacing: Theme.spacingExtraSmall) {
            glyphView(category: category, glyph: glyph)
            Text(category.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(glyph == .icon ? Theme.textPrimary : Theme.textOnAccent)
        .padding(Theme.spacingChip)
        .frame(minHeight: Theme.minTapArea)
        .background(glyph == .icon ? Theme.backgroundSecondary : Theme.accentPrimary)
        .clipShape(Capsule())
        .overlay {
            if glyph == .icon {
                Capsule().stroke(Theme.hairline, lineWidth: 1)
            }
        }
    }

    /// The leading slot. Branch swaps (icon↔checkmark↔ordinal) fade via the
    /// opacity transition; digit-to-digit changes fade via the opacity
    /// content transition. The explicit animation is scoped to the slot so it
    /// survives ancestor nil-transactions (Track's `bottomFlow` keeps the
    /// Start/Stop swap instant without silencing this fade).
    @ViewBuilder
    private func glyphView(category: Category, glyph: ChipGlyph) -> some View {
        Group {
            switch glyph {
            case .icon:
                Image(systemName: CatalogIcon(validated: category.icon).displaySymbol)
                    .font(.system(size: symbolFontSize, weight: .regular))
            case .checkmark:
                Image(systemName: "checkmark")
                    .font(.system(size: symbolFontSize, weight: .semibold))
            case let .ordinal(position):
                Text("\(position)")
                    .font(.system(size: ordinalFontSize(position: position), weight: .semibold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
        .frame(width: symbolSlotSize, height: symbolFontSize)
        .accessibilityHidden(true)
        .transition(.opacity)
        .contentTransition(.opacity)
        .animation(.easeInOut(duration: Self.glyphFadeDuration), value: glyph)
    }
}
