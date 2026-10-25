import SwiftUI

/// A labeled text field with a single unified error label below it.
///
/// Follows Requirements U4: several similar errors collapse into one merged
/// message per field. The caller provides the merged message.
struct TextFieldWithError: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let error: String?
    let keyboardType: UIKeyboardType
    let textContentType: UITextContentType?
    let submitLabel: SubmitLabel
    let autocapitalization: UITextAutocapitalizationType
    let accessibilityId: String
    let onSubmit: () -> Void
    /// Focus binding applied to the inner `TextField` (issue #82): Apple's
    /// `focused(_:)` moves focus to *the modified view*, so the binding
    /// belongs on the field itself — never on a wrapper container.
    let focused: FocusState<Bool>.Binding
    /// Opt-in trailing clear (×, issue #42): defaults to off so existing
    /// callers (email-OTP) are unaffected; the category editor opts in.
    /// The caller owns visibility (focused AND non-empty) via
    /// `ClearButtonVisibility` and passes the result as `showClear`.
    var showClear: Bool = false
    var onClear: (() -> Void)?
    var clearAccessibilityId: String = ""
    var clearAccessibilityLabel: String = L10n.nameClear.text

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSmall) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 0) {
                TextField(placeholder, text: $text)
                    .textContentType(textContentType)
                    .keyboardType(keyboardType)
                    .autocapitalization(autocapitalization)
                    .autocorrectionDisabled()
                    .submitLabel(submitLabel)
                    // Stable row height (issue #82): the 44 pt clear button
                    // fits inside an already-44 pt field, so its appearance
                    // never grows the row or shifts content below.
                    .frame(maxWidth: .infinity, minHeight: Theme.minTapArea)
                    .focused(focused)
                    .accessibilityIdentifier(accessibilityId)
                    .onSubmit(onSubmit)
                if showClear, let onClear {
                    ClearTextButton(
                        action: onClear,
                        accessibilityId: clearAccessibilityId,
                        accessibilityLabel: clearAccessibilityLabel
                    )
                }
            }
                // Compact card (issue #82): horizontal-only padding keeps the
                // row at the 44 pt minimum — matching the NamePicker field —
                // instead of ballooning to ~76 pt with full padding.
                .padding(.horizontal, Theme.spacingMedium)
                .background(Theme.backgroundSecondary)
                .cornerRadius(Theme.cornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .stroke(error != nil ? Theme.danger : Theme.hairline, lineWidth: 1)
                )

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("\(accessibilityId)Error")
            }
        }
    }
}

#if DEBUG
private struct TextFieldWithErrorPreview: View {
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextFieldWithError(
            title: "Email",
            placeholder: "Enter your email",
            text: $text,
            error: text.isEmpty ? "Email is required." : nil,
            keyboardType: .emailAddress,
            textContentType: .emailAddress,
            submitLabel: .continue,
            autocapitalization: .none,
            accessibilityId: "PreviewTextField",
            onSubmit: {},
            focused: $isFocused
        )
        .padding()
    }
}

#Preview("Text Field With Error") {
    TextFieldWithErrorPreview()
}
#endif
