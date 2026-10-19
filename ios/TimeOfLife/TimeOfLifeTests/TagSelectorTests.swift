import Testing
import Foundation
@testable import TimeOfLife

@Suite("TagSelector.glyph")
struct TagSelectorTests {

    @Test("unselected chips show the icon")
    func unselectedShowsIcon() {
        #expect(TagSelector.glyph(for: "c1", in: []) == .icon)
        #expect(TagSelector.glyph(for: "c1", in: ["c2", "c3"]) == .icon)
    }

    @Test("a lone selection shows the checkmark")
    func loneSelectionShowsCheckmark() {
        #expect(TagSelector.glyph(for: "c1", in: ["c1"]) == .checkmark)
    }

    @Test("two selections show ordinals in tap order, not catalog order")
    func twoSelectionsShowOrdinals() {
        let selected = ["c2", "c1"]
        #expect(TagSelector.glyph(for: "c2", in: selected) == .ordinal(1))
        #expect(TagSelector.glyph(for: "c1", in: selected) == .ordinal(2))
    }

    @Test("deselecting the middle renumbers densely")
    func deselectRenumbersDensely() {
        let selected = ["c1", "c3"]
        #expect(TagSelector.glyph(for: "c1", in: selected) == .ordinal(1))
        #expect(TagSelector.glyph(for: "c3", in: selected) == .ordinal(2))
        #expect(TagSelector.glyph(for: "c2", in: selected) == .icon)
    }

    @Test("returning to one selection restores the checkmark")
    func backToOneRestoresCheckmark() {
        #expect(TagSelector.glyph(for: "c3", in: ["c3"]) == .checkmark)
    }

    @Test("three selections show ordinals in tap order")
    func threeSelectionsShowOrdinals() {
        let selected = ["c3", "c1", "c2"]
        #expect(TagSelector.glyph(for: "c3", in: selected) == .ordinal(1))
        #expect(TagSelector.glyph(for: "c1", in: selected) == .ordinal(2))
        #expect(TagSelector.glyph(for: "c2", in: selected) == .ordinal(3))
    }

    @Test("ordinals cap at 99")
    func ordinalsCapAt99() {
        let selected = (0..<100).map { "c\($0)" }
        #expect(TagSelector.glyph(for: "c0", in: selected) == .ordinal(1))
        #expect(TagSelector.glyph(for: "c98", in: selected) == .ordinal(99))
        #expect(TagSelector.glyph(for: "c99", in: selected) == .ordinal(99))
    }
}

@MainActor
@Suite("TagSelector.createChip")
struct TagSelectorCreateChipTests {

    private func makeSelector(onCreate: (@Sendable () -> Void)?) -> TagSelector {
        TagSelector(
            options: [Category(id: "c1", name: "Work", icon: "briefcase")],
            selected: [],
            onToggle: { _ in },
            onCreate: onCreate,
            accessibilityId: "TestTags"
        )
    }

    @Test("creation chip renders if and only if onCreate is provided")
    func createChipOptIn() {
        #expect(makeSelector {}.showsCreateChip)
        #expect(!makeSelector(onCreate: nil).showsCreateChip)
    }

    @Test("viewport clamps at 4 rows plus inter-row gaps")
    func clampMath() {
        #expect(ChipViewport.clampedHeight(rowHeight: 44, spacing: 8) == 4.0 * 44 + 3 * 8)
        #expect(ChipViewport.clampedHeight(rowHeight: 60, spacing: 8) == 4.0 * 60 + 3 * 8)
    }

    @Test("capped categories viewport adds bleed without changing the row budget")
    func cappedBleed() {
        let base: CGFloat = ChipViewport.clampedHeight(rowHeight: 44, spacing: 8)
        let capped: CGFloat = base + ChipViewport.borderBleed
        #expect(ChipViewport.borderBleed == 2)
        #expect(base == 200)
        #expect(capped == 202)
    }

    @Test("both dividers hide when the catalog fits without scrolling")
    func edgesFitHideBoth() {
        let edges = ChipViewport.edges(offsetY: 0, containerHeight: 200, contentHeight: 100)
        #expect(edges.atTop)
        #expect(edges.atEnd)
    }

    @Test("top divider hides at rest, bottom shows while content remains")
    func edgesAtTop() {
        let edges = ChipViewport.edges(offsetY: 0, containerHeight: 178, contentHeight: 400)
        #expect(edges.atTop)
        #expect(!edges.atEnd)
    }

    @Test("both dividers show mid-scroll")
    func edgesMidScroll() {
        let edges = ChipViewport.edges(offsetY: 100, containerHeight: 178, contentHeight: 400)
        #expect(!edges.atTop)
        #expect(!edges.atEnd)
    }

    @Test("bottom divider hides at the content end")
    func edgesAtEnd() {
        let edges = ChipViewport.edges(offsetY: 222, containerHeight: 178, contentHeight: 400)
        #expect(!edges.atTop)
        #expect(edges.atEnd)
    }
}

@Suite("ChipViewport.adaptive")
struct ChipViewportAdaptiveTests {

    @Test("fixed cap is the 4-row clamp plus the border bleed")
    func fixedCapAddsBleed() {
        #expect(ChipViewport.maxHeight(rowHeight: 44, spacing: 8) == 202)
        #expect(ChipViewport.maxHeight(rowHeight: 44, spacing: 8) == ChipViewport.clampedHeight(
            rowHeight: 44,
            spacing: 8
        ) + ChipViewport.borderBleed)
    }

    @Test("nil budget keeps the fixed cap (first paint, previews, entry forms)")
    func nilBudgetKeepsFixedCap() {
        #expect(ChipViewport.viewportHeight(rowHeight: 44, spacing: 8, availableHeight: nil) == 202)
    }

    @Test("generous budget keeps the fixed cap (tall phones unchanged)")
    func generousBudgetKeepsFixedCap() {
        #expect(ChipViewport.viewportHeight(rowHeight: 44, spacing: 8, availableHeight: 1000) == 202)
        #expect(ChipViewport.viewportHeight(rowHeight: 44, spacing: 8, availableHeight: 202) == 202)
    }

    @Test("tight budget shrinks the viewport (compact phones, internal scroll)")
    func tightBudgetShrinks() {
        #expect(ChipViewport.viewportHeight(rowHeight: 44, spacing: 8, availableHeight: 150) == 150)
        #expect(ChipViewport.viewportHeight(rowHeight: 44, spacing: 8, availableHeight: 90) == 90)
    }

    @Test("viewport never exceeds the fixed cap")
    func neverExceedsCap() {
        for budget in [0, 44, 100, 202, 500] as [CGFloat] {
            let height = ChipViewport.viewportHeight(
                rowHeight: 44,
                spacing: 8,
                availableHeight: CGFloat(budget)
            )
            #expect(height <= 202)
        }
    }

    @Test("starved budget floors at one row plus bleed, never collapses")
    func starvedBudgetFloorsAtOneRow() {
        let floor: CGFloat = 44 + 2
        #expect(ChipViewport.viewportHeight(rowHeight: 44, spacing: 8, availableHeight: 0) == floor)
        #expect(ChipViewport.viewportHeight(rowHeight: 44, spacing: 8, availableHeight: -50) == floor)
        #expect(ChipViewport.viewportHeight(rowHeight: 44, spacing: 8, availableHeight: 10) == floor)
    }
}
