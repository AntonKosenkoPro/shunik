import SwiftUI

/// Course create/edit form (§6.3). New courses default to `route "oral"`
/// (mirroring the backend), status `"active"`, and the passed `petID`
/// (a pet picker appears when the household has more than one pet).
/// Editing also exposes the status picker. Save stays disabled while the
/// drug name is blank, while scheduled times fail to parse, or while a
/// weekdays course has no day selected — no new strings needed.
struct CourseFormView: View {
    @EnvironmentObject private var viewModel: MedicationsViewModel
    @Environment(\.dismiss)
    private var dismiss

    private let courseID: String?
    @State private var petID: String
    @State private var drug = ""
    @State private var doseAmount = ""
    @State private var doseUnit = ""
    @State private var route = "oral"
    @State private var scheduleKind = "daily"
    @State private var times = ""
    @State private var weekdays = Set<Int>()
    @State private var durationDays = 0
    @State private var hasEndsOn = false
    @State private var endsOn = Date()
    @State private var status = "active"
    @State private var instructions = ""
    @State private var infoRef = ""

    init(courseID: String?, petID: String) {
        self.courseID = courseID
        self.petID = petID
    }

    var body: some View {
        NavigationStack {
            Form {
                petSection
                drugSection
                scheduleSection
                windowSection
                if courseID != nil {
                    statusSection
                }
                notesSection
            }
            .navigationTitle(courseID == nil ? L10n.medsCourseAdd.text : L10n.medsCourseEdit.text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel.text) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.commonSave.text) { save() }
                        .disabled(!isValid)
                }
            }
            .task {
                if let courseID, viewModel.courseEvent(id: courseID) == nil {
                    await viewModel.load()
                }
                seedFromExisting()
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder private var petSection: some View {
        if viewModel.pets.count > 1 {
            Section {
                Picker(L10n.petsTitle.text, selection: $petID) {
                    ForEach(viewModel.pets, id: \.id) { pet in
                        Text(pet.name).tag(pet.id)
                    }
                }
            }
        }
    }

    private var drugSection: some View {
        Section {
            TextField(L10n.medsDrug.text, text: $drug)
            TextField(L10n.medsDose.text, text: $doseAmount)
            TextField(L10n.medsDoseUnit.text, text: $doseUnit)
            TextField(L10n.medsRoute.text, text: $route)
        }
    }

    private var scheduleSection: some View {
        Section(L10n.medsSchedule.text) {
            Picker(L10n.medsSchedule.text, selection: $scheduleKind) {
                Text(L10n.medsScheduleDaily.text).tag("daily")
                Text(L10n.medsScheduleWeekdays.text).tag("weekdays")
                Text(L10n.medsSchedulePrn.text).tag("prn")
            }
            .pickerStyle(.segmented)
            if scheduleKind != "prn" {
                TextField(L10n.medsTimes.text, text: $times, prompt: Text(L10n.medsTimesHint.text))
                    .textInputAutocapitalization(.never)
            }
            if scheduleKind == "weekdays" {
                weekdaySelector
            }
        }
    }

    /// Monday-first toggle grid over ISO days 1..7. Labels come from the
    /// system locale (`shortWeekdaySymbols`) — not app strings.
    private var weekdaySelector: some View {
        let symbols = Calendar.current.shortWeekdaySymbols
        let order = [1, 2, 3, 4, 5, 6, 0]
        return VStack(alignment: .leading, spacing: Theme.spacingSmall) {
            Text(L10n.medsWeekdays.text)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: Theme.spacingSmall) {
                ForEach(order, id: \.self) { index in
                    let iso = (index + 6) % 7 + 1
                    Button(symbols[index]) {
                        if weekdays.contains(iso) {
                            weekdays.remove(iso)
                        } else {
                            weekdays.insert(iso)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(weekdays.contains(iso) ? Theme.accentPrimary : Theme.textSecondary)
                }
            }
        }
    }

    private var windowSection: some View {
        Section {
            HStack {
                Text(L10n.medsDuration.text)
                Spacer()
                TextField("", value: $durationDays, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80)
            }
            Toggle(L10n.medsEndsOn.text, isOn: $hasEndsOn)
            if hasEndsOn {
                DatePicker(L10n.medsEndsOn.text, selection: $endsOn, displayedComponents: .date)
            }
        }
    }

    private var statusSection: some View {
        Section(L10n.medsStatus.text) {
            Picker(L10n.medsStatus.text, selection: $status) {
                Text(L10n.medsStatusActive.text).tag("active")
                Text(L10n.medsStatusPaused.text).tag("paused")
                Text(L10n.medsStatusDone.text).tag("done")
                Text(L10n.medsStatusStopped.text).tag("stopped")
            }
        }
    }

    private var notesSection: some View {
        Section {
            TextField(L10n.medsInstructions.text, text: $instructions)
            TextField(L10n.medsInfoRef.text, text: $infoRef)
                .textInputAutocapitalization(.never)
        }
    }

    // MARK: - Logic

    private var isScheduled: Bool { scheduleKind != "prn" }

    private var isValid: Bool {
        guard !drug.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard isScheduled else { return true }
        guard !MedicationEngine.parseTimes(times).isEmpty else { return false }
        if scheduleKind == "weekdays", weekdays.isEmpty { return false }
        return true
    }

    private func seedFromExisting() {
        if petID.isEmpty, let first = viewModel.pets.first {
            petID = viewModel.effectivePetID ?? first.id
        }
        guard let courseID,
              let event = viewModel.courseEvent(id: courseID),
              let detail = event.course
        else { return }
        petID = event.petID
        drug = detail.drugName
        doseAmount = detail.doseAmount
        doseUnit = detail.doseUnit
        route = detail.route
        scheduleKind = detail.scheduleKind
        times = detail.scheduleTimes
        weekdays = Set(MedicationEngine.parseWeekdays(detail.scheduleWeekdays))
        durationDays = detail.durationDays
        if let endsOnDate = MedicationEngine.parseDateOnly(detail.endsOn) {
            hasEndsOn = true
            endsOn = endsOnDate
        }
        status = detail.status
        instructions = detail.instructions
        infoRef = detail.infoRef
    }

    private func save() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let detail = MedCourseRecord(
            drugName: drug.trimmingCharacters(in: .whitespaces),
            doseAmount: doseAmount, doseUnit: doseUnit, route: route,
            scheduleKind: scheduleKind, scheduleTimes: times,
            scheduleWeekdays: weekdays.sorted().map(String.init).joined(separator: ","),
            durationDays: max(0, durationDays),
            endsOn: hasEndsOn ? formatter.string(from: endsOn) : nil,
            status: courseID == nil ? "active" : status,
            instructions: instructions, infoRef: infoRef
        )
        let targetPetID = petID.isEmpty ? (viewModel.effectivePetID ?? "") : petID
        Task {
            await viewModel.saveCourse(courseID: courseID, petID: targetPetID, detail: detail)
            dismiss()
        }
    }
}
