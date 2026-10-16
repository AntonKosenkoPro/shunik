import SwiftUI

/// Section title used in editor screens to label input sections, and in
/// History as the day-group header (Design/COMPONENTS.md). Purely
/// presentational — no state, no action. In History the header is a static
/// two-line block (day label + total subline, Calendar-Agenda-like); it has
/// no notion of scrolling or pinning.
struct SectionHeader: View {
    let title: String
    /// Optional second line under the title (History day total). Nil renders
    /// the single-line editor presentation exactly as before.
    let subtitle: String?

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(Theme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
        }
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("SectionHeader")
    }
}

#if DEBUG
#Preview("Section header") {
    SectionHeader(title: "Icon")
        .padding(.horizontal, Theme.spacingMedium)
        .background(Theme.backgroundPrimary)
}

#Preview("Section header with subtitle") {
    SectionHeader(title: "Today", subtitle: "8h 30m tracked")
        .padding(.horizontal, Theme.spacingMedium)
        .background(Theme.backgroundPrimary)
}
#endif
