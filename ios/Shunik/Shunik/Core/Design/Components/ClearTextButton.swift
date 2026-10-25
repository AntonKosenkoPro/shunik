import SwiftUI

/// Testable visibility rule for every clear (`×`) button (issue #42
/// follow-ups): shown only when the field is focused AND holds non-empty
/// text, never when locked/read-only. Call sites pass their existing
/// `@FocusState` plus the draft text plus the lock state. Whitespace-only
/// text counts as non-empty (one tap clears it to truly empty).
enum ClearButtonVisibility {
    static func shouldShow(isFocused: Bool, text: String, isLocked: Bool = false) -> Bool {
        isFocused && !text.isEmpty && !isLocked
    }
}

/// Trailing clear (`×`) button for plain-text fields
/// (feat-name-field-affordances): one tap empties the field. Shared by the
/// Track name field, the entry-form name/notes rows, and the category
/// editor so every presentation stays identical. Visibility is owned by the
/// caller via `ClearButtonVisibility` (focused AND non-empty only).
/// The Apple-standard trailing look (reference in #42): a small dim
/// `xmark.circle.fill` tucked at the field's trailing edge — the visible
/// glyph is 16 pt `Theme.textSecondary` at reduced opacity while the
/// Button keeps the 44 pt accessible tap target.
struct ClearTextButton: View {
    /// Action run on tap (clears the caller's draft text).
    let action: () -> Void
    /// Accessibility identifier supplied by the caller
    /// (`TimerNameClearButton` / `EntryNameClearButton` /
    /// `CategoryNameClearButton`).
    let accessibilityId: String
    /// VoiceOver label; defaults to the name-field label — notes and
    /// category callers pass their own.
    let accessibilityLabel: String

    init(
        action: @escaping () -> Void,
        accessibilityId: String,
        accessibilityLabel: String = L10n.nameClear.text
    ) {
        self.action = action
        self.accessibilityId = accessibilityId
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary.opacity(Theme.opacityClearGlyph))
                .frame(
                    minWidth: Theme.minTapArea,
                    minHeight: Theme.minTapArea,
                    alignment: .trailing
                )
                .padding(.trailing, Theme.spacingSmall)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityId)
        .accessibilityLabel(accessibilityLabel)
    }
}

#if DEBUG
#Preview("Clear Text Button") {
    ClearTextButton(action: {}, accessibilityId: "PreviewClearButton")
        .padding()
}
#endif
