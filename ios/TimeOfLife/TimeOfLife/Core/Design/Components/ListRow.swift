import SwiftUI

/// A single row in a settings or history list (Design/COMPONENTS.md).
struct ListRow<Trailing: View>: View {
    let icon: String?
    let title: String
    let subtitle: String?
    /// Optional tint override for destructive rows. When `nil` (the default)
    /// the icon uses `Theme.accentPrimary` and the title uses
    /// `Theme.textPrimary`; pass `Theme.danger` so both warn together.
    /// An outer `.foregroundStyle` cannot do this: the explicit inner styles
    /// below always win over an inherited style.
    let tint: Color?
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        icon: String? = nil,
        subtitle: String? = nil,
        tint: Color? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.trailing = trailing
    }
    var body: some View {
        HStack(spacing: Theme.spacingMedium) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(tint ?? Theme.accentPrimary)
                    .font(.body)
                    .frame(width: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(tint ?? Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, Theme.spacingSmall)
        .frame(minHeight: Theme.minTapArea)
        .contentShape(Rectangle())
    }
}

#if DEBUG
#Preview("List Row") {
    ListRow(title: L10n.accountTitle.text, icon: "clock", subtitle: "8,040") {
        Text(L10n.commonOk.text)
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
    }
    .padding(.horizontal)
    .background(Theme.backgroundPrimary)
}
#endif
