import SwiftUI

/// Weight history for one pet (§6.2): the latest weigh-in rendered through
/// the per-device `UnitLens`, the trend versus the previous weigh-in
/// (epsilon: sub-10 g jitter is flat), and the newest-first history list.
struct WeightHistoryView: View {
    let petID: String

    @EnvironmentObject var container: AppContainer
    @State private var weighIns: [EventRecord] = []
    @State private var errorMessage: String?

    init(petID: String) {
        self.petID = petID
    }

    var body: some View {
        Group {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(Theme.danger)
            } else if weighIns.isEmpty {
                Text(L10n.timelineEmptyHint.text)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                List {
                    if let latest = weighIns.first {
                        Section {
                            latestRow(latest)
                        }
                    }
                    Section(L10n.weightHistory.text) {
                        ForEach(weighIns, id: \.id) { event in
                            historyRow(event)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(L10n.eventKindWeight.text)
        .task(id: petID) {
            await load()
        }
    }

    private func latestRow(_ latest: EventRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: Theme.spacingExtraSmall) {
                Text(displayText(grams: latest.weight?.grams))
                    .foregroundStyle(Theme.textPrimary)
                Text(latest.timelineDateText)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if weighIns.count > 1, let trend = trend() {
                Text(trend.label)
                    .foregroundStyle(Theme.accentPrimary)
            }
        }
    }

    private func historyRow(_ event: EventRecord) -> some View {
        HStack {
            Text(displayText(grams: event.weight?.grams))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(event.timelineDateText)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func displayText(grams: Int64?) -> String {
        guard let grams else { return "" }
        let display = UnitLens.display(grams: grams, system: UnitLens.current)
        return "\(display.value) \(display.unit)"
    }

    private func trend() -> WeightTrend? {
        guard weighIns.count > 1,
              let current = weighIns.first?.weight?.grams,
              let previous = weighIns.dropFirst().first?.weight?.grams
        else {
            return nil
        }
        return UnitLens.trend(current: current, previous: previous)
    }

    private func load() async {
        do {
            let events = try await container.localStore.listEvents(petID: petID)
            weighIns = events.filter { $0.kind == "weight" }
            errorMessage = nil
        } catch {
            errorMessage = L10n.errorLocalPersistence.text
        }
    }
}

#if DEBUG
#Preview("Weight history") {
    let container = AppContainer.production()
    NavigationStack {
        WeightHistoryView(petID: "pet-1")
            .environmentObject(container)
    }
}
#endif
