import SwiftUI

/// Medications root (§6.3): a Due feed (pendings due through end-of-today
/// with Taken/Missed/Skipped buttons) plus the Courses list (drug, status,
/// adherence, PRN log shortcut). Parameterless: it builds its view model
/// from the environment graph and shares it down via `environmentObject`,
/// so `CourseFormView` / `CourseDetailView` keep their spec initializers.
struct MedicationsView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var session: SessionStore
    @State private var viewModel: MedicationsViewModel?

    var body: some View {
        Group {
            if let viewModel {
                MedicationsBodyView(viewModel: viewModel)
                    .environmentObject(viewModel)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(L10n.medsTitle.text)
        .task {
            if viewModel == nil {
                let userID: String
                if case let .signedIn(signed) = session.state {
                    userID = signed.id
                } else {
                    userID = ""
                }
                let created = MedicationsViewModel(
                    store: container.localStore,
                    undo: container.undoBuffer,
                    sync: container.syncController,
                    sessionUserID: userID
                )
                viewModel = created
                await created.load()
            }
        }
        .accessibilityIdentifier("Medications")
    }
}

private struct MedicationsBodyView: View {
    @ObservedObject var viewModel: MedicationsViewModel
    @State private var showingAdd = false

    var body: some View {
        List {
            if viewModel.requiresChrome {
                petScopeSection
            }
            dueSection
            coursesSection
        }
        .navigationTitle(L10n.medsTitle.text)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("MedsAddCourse")
            }
        }
        .sheet(isPresented: $showingAdd) {
            CourseFormView(courseID: nil, petID: viewModel.effectivePetID ?? "")
        }
        .task {
            await viewModel.load()
        }
        .refreshable {
            await viewModel.load()
        }
    }

    private var petScopeSection: some View {
        Section {
            Picker(L10n.petsTitle.text, selection: $viewModel.selectedPetID) {
                Text(L10n.commonAll.text).tag(nil as String?)
                ForEach(viewModel.pets, id: \.id) { pet in
                    Text(pet.name).tag(pet.id as String?)
                }
            }
            .onChange(of: viewModel.selectedPetID) {
                Task { await viewModel.load() }
            }
        }
    }

    @ViewBuilder private var dueSection: some View {
        Section(L10n.medsDue.text) {
            if viewModel.dueIntakes.isEmpty {
                Text(L10n.medsEmptyHint.text)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(viewModel.dueIntakes, id: \.intake.id) { row in
                    VStack(alignment: .leading, spacing: Theme.spacingExtraSmall) {
                        HStack {
                            Text(dueTitle(row: row))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(dueTime(row.intake))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        HStack(spacing: Theme.spacingSmall) {
                            markButton(row: row, status: "taken", label: L10n.medsMarkTaken.text)
                            markButton(row: row, status: "missed", label: L10n.medsMarkMissed.text)
                            markButton(row: row, status: "skipped", label: L10n.medsMarkSkipped.text)
                        }
                    }
                }
            }
        }
    }

    private func dueTitle(row: (intake: IntakeRecord, course: EventRecord, petName: String)) -> String {
        let drug = row.course.course?.drugName ?? row.course.title
        if viewModel.requiresChrome, !row.petName.isEmpty {
            return "\(row.petName) · \(drug)"
        }
        return drug
    }

    private func dueTime(_ intake: IntakeRecord) -> String {
        guard let dueAt = intake.dueAt,
              let date = RFC3339Milli.parse(dueAt)
        else { return "" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private func markButton(row: (intake: IntakeRecord, course: EventRecord, petName: String), status: String, label: String) -> some View {
        Button(label) {
            Task { await viewModel.mark(row.intake, status: status) }
        }
        .buttonStyle(.bordered)
        .tint(status == "taken" ? Theme.accentPrimary : Theme.textSecondary)
    }

    private var coursesSection: some View {
        Section(L10n.medsCourses.text) {
            if viewModel.courses.isEmpty {
                VStack(alignment: .leading, spacing: Theme.spacingExtraSmall) {
                    Text(L10n.medsEmpty.text)
                        .foregroundStyle(Theme.textPrimary)
                    Text(L10n.medsEmptyHint.text)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                ForEach(viewModel.courses, id: \.id) { course in
                    NavigationLink {
                        CourseDetailView(courseID: course.id)
                    } label: {
                        courseRow(course: course)
                    }
                }
            }
        }
    }

    private func courseRow(course: EventRecord) -> some View {
        let detail = course.course
        let adherence = viewModel.adherence(courseID: course.id)
        return HStack {
            VStack(alignment: .leading, spacing: Theme.spacingExtraSmall) {
                Text(detail?.drugName ?? course.title)
                    .foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(medicationScheduleSummary(detail))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Theme.spacingExtraSmall) {
                Text("\(adherence.taken)/\(adherence.denominator)")
                    .foregroundStyle(Theme.textPrimary)
                if detail?.scheduleKind == "prn" {
                    Button(L10n.medsLogDose.text) {
                        Task { await viewModel.logPrn(course: course) }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}
