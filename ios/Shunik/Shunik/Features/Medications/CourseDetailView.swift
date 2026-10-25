import SwiftUI

/// Course detail (§6.3): header (drug, dose, schedule summary, status,
/// adherence) + intakes newest-first with mark buttons on pendings + Stop
/// (confirm via `meds.stopTitle` / `meds.stopMessage`) + undo-buffered
/// delete. When the course row is gone (deleted, settled history kept),
/// the header falls back to the view model's deletion snapshot.
/// Newest-first is a view ordering only; the store keeps earliest-first.
struct CourseDetailView: View {
    @EnvironmentObject private var viewModel: MedicationsViewModel
    @Environment(\.dismiss)
    private var dismiss

    private let courseID: String
    @State private var showingStopConfirm = false
    @State private var showingEdit = false

    init(courseID: String) {
        self.courseID = courseID
    }

    var body: some View {
        Group {
            if let event = viewModel.courseEvent(id: courseID) {
                detailContent(event: event)
            } else {
                Text(L10n.medsEmpty.text)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .navigationTitle(viewModel.courseEvent(id: courseID)?.course?.drugName ?? viewModel.courseEvent(id: courseID)?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(L10n.commonEdit.text) {
                    showingEdit = true
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            if let event = viewModel.courseEvent(id: courseID) {
                CourseFormView(courseID: event.id, petID: event.petID)
            }
        }
        .alert(L10n.medsStopTitle.text, isPresented: $showingStopConfirm) {
            Button(L10n.medsStop.text, role: .destructive) {
                stop()
            }
            Button(L10n.commonCancel.text, role: .cancel) {}
        } message: {
            Text(L10n.medsStopMessage.text)
        }
        .task {
            await viewModel.load()
        }
    }

    // MARK: - Content

    private func detailContent(event: EventRecord) -> some View {
        let detail = event.course
        let adherence = viewModel.adherence(courseID: courseID)
        return List {
            Section {
                headerRow(label: L10n.medsDrug.text, value: detail?.drugName ?? event.title)
                headerRow(
                    label: L10n.medsDose.text,
                    value: "\(detail?.doseAmount ?? "") \(detail?.doseUnit ?? "")"
                        .trimmingCharacters(in: .whitespaces)
                )
                if let detail {
                    headerRow(label: L10n.medsSchedule.text, value: medicationScheduleSummary(detail))
                    headerRow(label: L10n.medsStatus.text, value: statusText(detail.status))
                    headerRow(
                        label: L10n.medsAdherence.text,
                        value: "\(adherence.taken)/\(adherence.denominator)"
                    )
                }
            }
            Section(L10n.medsIntakes.text) {
                ForEach(viewModel.intakes(courseID: courseID), id: \.id) { intake in
                    intakeRow(intake)
                }
            }
            Section {
                if detail?.status == "active" {
                    Button(L10n.medsStop.text, role: .destructive) {
                        showingStopConfirm = true
                    }
                }
                Button(L10n.commonDelete.text, role: .destructive) {
                    delete(event: event)
                }
            }
        }
    }

    private func headerRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func statusText(_ status: String) -> String {
        switch status {
        case "active": return L10n.medsStatusActive.text
        case "paused": return L10n.medsStatusPaused.text
        case "done": return L10n.medsStatusDone.text
        case "stopped": return L10n.medsStatusStopped.text
        default: return status
        }
    }

    private func intakeRow(_ intake: IntakeRecord) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingExtraSmall) {
            HStack {
                Text(intakeStatusText(intake.status))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(intakeDateText(intake))
                    .foregroundStyle(Theme.textSecondary)
            }
            if !intake.doseSnapshot.isEmpty {
                Text(intake.doseSnapshot)
                    .foregroundStyle(Theme.textSecondary)
            }
            if intake.status == "pending" {
                HStack(spacing: Theme.spacingSmall) {
                    markButton(intake: intake, status: "taken", label: L10n.medsMarkTaken.text)
                    markButton(intake: intake, status: "missed", label: L10n.medsMarkMissed.text)
                    markButton(intake: intake, status: "skipped", label: L10n.medsMarkSkipped.text)
                }
            }
        }
    }

    private func intakeStatusText(_ status: String) -> String {
        switch status {
        case "taken": return L10n.medsIntakeTaken.text
        case "missed": return L10n.medsIntakeMissed.text
        case "skipped": return L10n.medsIntakeSkipped.text
        default: return L10n.medsIntakePending.text
        }
    }

    private func intakeDateText(_ intake: IntakeRecord) -> String {
        let raw = intake.dueAt ?? intake.takenAt ?? ""
        guard let date = RFC3339Milli.parse(raw) else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func markButton(intake: IntakeRecord, status: String, label: String) -> some View {
        Button(label) {
            Task { await viewModel.mark(intake, status: status) }
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Actions

    private func stop() {
        guard let event = viewModel.courseEvent(id: courseID) else { return }
        Task {
            await viewModel.stopCourse(event)
        }
    }

    private func delete(event: EventRecord) {
        Task {
            await viewModel.deleteCourse(event)
            dismiss()
        }
    }
}
