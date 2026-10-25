import SwiftUI

/// Centered inline error message used when the error is not tied to a
/// specific field (for example a server or offline error).
struct ErrorBanner: View {
    let message: String
    let accessibilityId: String

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(Theme.danger)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier(accessibilityId)
    }
}

#if DEBUG
#Preview("Error Banner") {
    ErrorBanner(
        message: "Something went wrong. Please try again.",
        accessibilityId: "PreviewErrorBanner"
    )
    .padding()
}
#endif
