import SwiftUI

/// One-time code input rendered as a row of digit boxes.
///
/// Backed by a single hidden `TextField` so paste, SMS AutoFill, and typing
/// all flow through one continuous string. The component focuses itself on
/// appear (`.onAppear { isFocused = true }`) and never needs an external focus
/// binding; do not dismiss focus elsewhere. Auto-submit is the parent screen's
/// responsibility — this view only exposes the bound `code`.
struct OtpCodeField: View {
    @Binding var code: String
    var length: Int = 6
    let error: String?
    let isLoading: Bool
    let accessibilityId: String

    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme)
    private var colorScheme

    var body: some View {
        VStack(spacing: Theme.spacingSmall) {
            ZStack {
                TextField("", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isFocused)
                    .opacity(Theme.opacityHiddenField)
                    .accessibilityHidden(true)
                    .disabled(isLoading)

                HStack(spacing: Theme.spacingSmall) {
                    ForEach(0..<length, id: \.self) { index in
                        Text(digit(at: index))
                            .font(.title2.monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 44, height: 56)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
                                    .fill(Theme.backgroundSecondary)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall, style: .continuous)
                                    .stroke(borderColor(at: index), lineWidth: 1)
                            )
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
                .disabled(isLoading)
                .onTapGesture {
                    guard !isLoading else { return }
                    isFocused = true
                }
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("\(accessibilityId)Error")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: L10n.otpCodeLabel.text, locale: .current, length))
        .accessibilityValue(code)
        .accessibilityHint(L10n.otpCodeHint.text)
        .accessibilityIdentifier(accessibilityId)
        .onAppear {
            if !UIAccessibility.isVoiceOverRunning {
                isFocused = true
            }
        }
        .onChange(of: code) { _, newValue in
            // Sanitize to digits only and cap at `length`. Only write back when
            // the value actually changed to avoid a feedback loop.
            let digits = String(newValue.filter(\.isNumber).prefix(length))
            if digits != newValue {
                code = digits
            }
        }
        .onChange(of: error) { _, newError in
            // Re-focus the hidden field when a verification error appears so the
            // user can re-type immediately after the code is cleared.
            if newError != nil, !UIAccessibility.isVoiceOverRunning {
                isFocused = true
            }
        }
    }

    /// The digit displayed in the box at `index`, or an empty string when the
    /// code has not reached that position yet.
    private func digit(at index: Int) -> String {
        guard index < code.count else { return "" }
        return String(Array(code)[index])
    }

    /// Stroke color for the box at `index`: `Theme.danger` while an error is
    /// present, `Theme.accentPrimary` for the active box while focused, and
    /// `Theme.hairline` otherwise.
    private func borderColor(at index: Int) -> Color {
        if error != nil {
            return Theme.danger
        }
        let activeIndex = isFocused ? min(code.count, length - 1) : -1
        return index == activeIndex ? Theme.accentPrimary : Theme.hairline
    }
}

#if DEBUG

/// Preview wrapper holding the bound `code` in `@State`.
private struct OtpCodeFieldPreview: View {
    @State private var code: String
    let error: String?
    let isLoading: Bool

    init(code: String, error: String? = nil, isLoading: Bool = false) {
        self._code = State(initialValue: code)
        self.error = error
        self.isLoading = isLoading
    }

    var body: some View {
        OtpCodeField(
            code: $code,
            error: error,
            isLoading: isLoading,
            accessibilityId: "PreviewOtpCodeField"
        )
        .padding()
    }
}

#Preview("OTP Code Field — Default") {
    OtpCodeFieldPreview(code: "123")
}

#Preview("OTP Code Field — Error") {
    OtpCodeFieldPreview(code: "12", error: L10n.text(in: .default, code: "invalid_otp"))
}

#Preview("OTP Code Field — Loading") {
    OtpCodeFieldPreview(code: "123", isLoading: true)
}

#Preview("OTP Code Field — Dark") {
    OtpCodeFieldPreview(code: "123456")
        .preferredColorScheme(.dark)
}

#endif
