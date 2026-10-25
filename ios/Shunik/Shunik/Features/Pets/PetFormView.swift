import SwiftUI

/// Add/edit pet sheet (§6.1). Form logic lives here with direct store calls
/// via the passed-in store; the owner reloads through `onSaved`. Species is a
/// fixed dog/cat/other picker (stored verbatim); birthdate is an optional
/// `Date` mapped to the `yyyy-MM-dd` record string (nil = no birthdate).
/// Save stays disabled while the name is blank.
struct PetFormView: View {
    private let store: LocalStore
    private let existing: PetRecord?
    private let updatedBy: String
    private let onSaved: () -> Void

    @Environment(\.dismiss)
    private var dismiss

    @State private var name: String
    @State private var species: String
    @State private var hasBirthdate: Bool
    @State private var birthdate: Date
    @State private var notes: String
    @State private var errorMessage: String?

    init(store: LocalStore, existing: PetRecord?, updatedBy: String, onSaved: @escaping () -> Void) {
        self.store = store
        self.existing = existing
        self.updatedBy = updatedBy
        self.onSaved = onSaved
        _name = State(initialValue: existing?.name ?? "")
        _species = State(initialValue: existing?.species ?? "dog")
        _hasBirthdate = State(initialValue: existing?.birthdate != nil)
        _birthdate = State(initialValue: Self.date(from: existing?.birthdate) ?? Date())
        _notes = State(initialValue: existing?.notes ?? "")
    }

    private static let birthdateFormat = "yyyy-MM-dd"

    private static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = birthdateFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: string)
    }

    private static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = birthdateFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private var isSaveDisabled: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.petsName.text, text: $name)
                }
                Section(L10n.petsSpecies.text) {
                    Picker(L10n.petsSpecies.text, selection: $species) {
                        Text(L10n.petsSpeciesDog.text).tag("dog")
                        Text(L10n.petsSpeciesCat.text).tag("cat")
                        Text(L10n.petsSpeciesOther.text).tag("other")
                    }
                    .pickerStyle(.segmented)
                }
                Section(L10n.petsBirthdate.text) {
                    Toggle(L10n.petsBirthdate.text, isOn: $hasBirthdate)
                    if hasBirthdate {
                        DatePicker(
                            L10n.petsBirthdate.text,
                            selection: $birthdate,
                            displayedComponents: .date
                        )
                    } else {
                        Text(L10n.petsBirthdateNone.text)
                            .font(.body)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Section(L10n.petsNotes.text) {
                    TextField(L10n.petsNotes.text, text: $notes, axis: .vertical)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
            .navigationTitle(existing == nil ? L10n.petsAdd.text : L10n.petsEdit.text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel.text) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.commonSave.text) { save() }
                        .disabled(isSaveDisabled)
                }
            }
        }
    }

    private func save() {
        Task {
            do {
                let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let birthdateString = hasBirthdate ? Self.string(from: birthdate) : nil
                if let existing {
                    var record = existing
                    record.name = trimmedName
                    record.species = species
                    record.birthdate = birthdateString
                    record.notes = notes
                    _ = try await store.updatePet(
                        record,
                        baseUpdatedAt: existing.updatedAt,
                        updatedBy: updatedBy
                    )
                } else {
                    let householdID = await store.boundHouseholdID ?? ""
                    let record = PetRecord(
                        id: "",
                        householdID: householdID,
                        name: trimmedName,
                        species: species,
                        birthdate: birthdateString,
                        notes: notes,
                        createdAt: "",
                        updatedAt: "",
                        updatedBy: ""
                    )
                    _ = try await store.createPet(record, updatedBy: updatedBy)
                }
                onSaved()
                dismiss()
            } catch {
                errorMessage = L10n.errorLocalPersistence.text
            }
        }
    }
}
