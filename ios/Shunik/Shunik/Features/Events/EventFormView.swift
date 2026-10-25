import SwiftUI

/// Create + edit form for vaccination, grooming, and weight events (§6.2).
/// `eventID` nil creates; non-nil loads the row via `getEvent` and updates
/// with the `baseUpdatedAt` guard (a `staleBase` surfaces the generic
/// persistence message). Medication-course events are owned elsewhere and
/// never open here.
///
/// In create mode the kind picker switches between the three kinds; in edit
/// mode the kind is fixed. The title is required (Save stays disabled while
/// blank); weight stores integer grams parsed from the value + unit chips.
struct EventFormView: View {
    let eventID: String?
    let petID: String
    let kind: String

    @EnvironmentObject var container: AppContainer
    @Environment(\.dismiss)
    private var dismiss

    @State private var kindState: String
    @State private var title = ""
    @State private var occurredOn = Date()
    @State private var hasNextDue = false
    @State private var nextDue = Date()
    @State private var vaccine = ""
    @State private var batch = ""
    @State private var vet = ""
    @State private var service = ""
    @State private var place = ""
    @State private var notes = ""
    @State private var weightText = ""
    @State private var weightUnit = "g"
    @State private var system: UnitSystem = UnitLens.current
    @State private var baseUpdatedAt: String?
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(eventID: String?, petID: String, kind: String) {
        self.eventID = eventID
        self.petID = petID
        self.kind = kind
        _kindState = State(initialValue: kind)
        _system = State(initialValue: UnitLens.current)
        _weightUnit = State(initialValue: UnitLens.current == .metric ? "g" : "lb")
    }

    var body: some View {
        NavigationStack {
            Form {
                if eventID == nil {
                    Section {
                        Picker(L10n.eventTitle.text, selection: $kindState) {
                            Text(L10n.eventKindVaccination.text).tag("vaccination")
                            Text(L10n.eventKindGrooming.text).tag("grooming")
                            Text(L10n.eventKindWeight.text).tag("weight")
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section {
                    TextField(L10n.eventTitle.text, text: $title)
                    DatePicker(
                        L10n.eventOccurredOn.text,
                        selection: $occurredOn,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                    if kindState == "vaccination" || kindState == "grooming" {
                        nextDueRow
                    }
                }
                kindFields
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
            .navigationTitle(formTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel.text) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.commonSave.text) {
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .task {
                await loadIfEditing()
            }
        }
    }

    private var formTitle: String {
        switch kindState {
        case "vaccination": return L10n.eventKindVaccination.text
        case "grooming": return L10n.eventKindGrooming.text
        default: return L10n.eventKindWeight.text
        }
    }

    private var nextDueRow: some View {
        Group {
            if hasNextDue {
                DatePicker(
                    L10n.eventNextDue.text,
                    selection: $nextDue,
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                Button(L10n.eventNextDueNone.text, role: .cancel) {
                    hasNextDue = false
                }
            } else {
                Button(L10n.eventNextDue.text) {
                    hasNextDue = true
                }
            }
        }
    }

    @ViewBuilder private var kindFields: some View {
        switch kindState {
        case "vaccination":
            Section {
                TextField(L10n.eventVaccine.text, text: $vaccine)
                TextField(L10n.eventBatch.text, text: $batch)
                TextField(L10n.eventVet.text, text: $vet)
                TextField(L10n.eventNotes.text, text: $notes)
            }
        case "grooming":
            Section {
                TextField(L10n.eventService.text, text: $service)
                TextField(L10n.eventPlace.text, text: $place)
                TextField(L10n.eventNotes.text, text: $notes)
            }
        default:
            Section {
                TextField(L10n.weightValue.text, text: $weightText)
                    .keyboardType(.decimalPad)
                Picker(L10n.weightValue.text, selection: unitBinding) {
                    ForEach(unitsForSystem, id: \.self) { unit in
                        Text(unit).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                Picker(L10n.unitsSystem.text, selection: systemBinding) {
                    Text(L10n.unitsMetric.text).tag(UnitSystem.metric)
                    Text(L10n.unitsImperial.text).tag(UnitSystem.imperial)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    /// Unit chips for the active system: g|kg or oz|lb.
    private var unitsForSystem: [String] {
        system == .metric ? ["g", "kg"] : ["oz", "lb"]
    }

    /// Unit chip binding: switching chips live-converts the draft value so
    /// the mass stays identical across units.
    private var unitBinding: Binding<String> {
        Binding(
            get: { weightUnit },
            set: { convertDraft(to: $0, in: system) }
        )
    }

    /// System binding: persists the per-device choice and converts the draft
    /// into the other system's default unit (kg ↔ lb).
    private var systemBinding: Binding<UnitSystem> {
        Binding(
            get: { system },
            set: { newSystem in
                system = newSystem
                UnitLens.current = newSystem
                convertDraft(to: newSystem == .metric ? "kg" : "lb", in: newSystem)
            }
        )
    }

    private func convertDraft(to newUnit: String, in newSystem: UnitSystem) {
        if let grams = parsedGrams() {
            weightText = Self.valueString(grams: grams, unit: newUnit, system: newSystem)
        }
        weightUnit = newUnit
    }

    private static func valueString(grams: Int64, unit: String, system: UnitSystem) -> String {
        if unit == "oz" {
            return String(format: "%.1f", Double(grams) / 28.349523125)
        }
        return UnitLens.display(grams: grams, system: system).value
    }

    private var canSave: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if kindState == "weight" {
            return parsedGrams() != nil
        }
        return true
    }

    private func parsedGrams() -> Int64? {
        let normalized = weightText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized) else { return nil }
        return UnitLens.grams(value: value, unit: weightUnit)
    }

    private func loadIfEditing() async {
        guard let eventID else { return }
        do {
            guard let event = try await container.localStore.getEvent(id: eventID) else {
                errorMessage = L10n.errorLocalPersistence.text
                return
            }
            title = event.title
            kindState = event.kind
            occurredOn = RFC3339Milli.parse(event.occurredAt) ?? Date()
            if let nextDueAt = event.nextDueAt, let date = RFC3339Milli.parse(nextDueAt) {
                hasNextDue = true
                nextDue = date
            }
            vaccine = event.vaccination?.vaccine ?? ""
            batch = event.vaccination?.batch ?? ""
            vet = event.vaccination?.vet ?? ""
            service = event.grooming?.service ?? ""
            place = event.grooming?.place ?? ""
            notes = event.vaccination?.notes ?? event.grooming?.notes ?? ""
            if let grams = event.weight?.grams {
                weightText = UnitLens.display(grams: grams, system: system).value
            }
            baseUpdatedAt = event.updatedAt
        } catch {
            errorMessage = L10n.errorLocalPersistence.text
        }
    }

    private func save() async {
        guard canSave, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let userID = currentUserID()
            if let eventID, let base = baseUpdatedAt {
                let record = try makeRecord(id: eventID)
                _ = try await container.localStore.updateEvent(
                    record, baseUpdatedAt: base, updatedBy: userID
                )
            } else {
                let householdID = (try? await container.localStore.getPet(id: petID))?.householdID ?? ""
                _ = try await container.localStore.createEvent(
                    makeRecord(id: "", householdID: householdID), updatedBy: userID
                )
            }
            // A next-due creates a future buzz: ask once, then re-top-up
            // (first-due rule + reminder-engine refresh).
            if hasNextDue, kindState == "vaccination" || kindState == "grooming" {
                await container.reminderEngine.noteDueCreated()
            }
            await container.reminderEngine.refresh()
            dismiss()
        } catch {
            errorMessage = L10n.errorLocalPersistence.text
        }
    }

    private func currentUserID() -> String {
        if case let .signedIn(current) = container.sessionStore.state {
            return current.id
        }
        return ""
    }

    /// Builds the record through the flat JSON shape `EventRecord` decodes
    /// (there is no memberwise init — the sibling tests build records the
    /// same way). Missing timestamps fall back to empty strings; the store
    /// stamps them on create and echoes them on update.
    private func makeRecord(id: String, householdID: String = "") throws -> EventRecord {
        var dict: [String: Any] = [
            "id": id,
            "household_id": householdID,
            "pet_id": petID,
            "kind": kindState,
            "occurred_at": RFC3339Milli.format(occurredOn),
            "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
            "created_at": "",
            "updated_at": "",
            "updated_by": ""
        ]
        if hasNextDue, kindState == "vaccination" || kindState == "grooming" {
            dict["next_due_at"] = RFC3339Milli.format(nextDue)
        }
        switch kindState {
        case "vaccination":
            dict["vaccination"] = [
                "vaccine": vaccine, "batch": batch, "vet": vet, "notes": notes
            ]
        case "grooming":
            dict["grooming"] = [
                "service": service, "place": place, "notes": notes
            ]
        default:
            dict["weight"] = ["grams": parsedGrams() ?? 0]
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(EventRecord.self, from: data)
    }
}

#if DEBUG
#Preview("Event form") {
    let container = AppContainer.production()
    EventFormView(eventID: nil, petID: "pet-1", kind: "weight")
        .environmentObject(container)
}
#endif
