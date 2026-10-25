import SwiftUI

/// Pet detail (§6.1): header (name/species/birth year) plus History,
/// Medications, Documents, and Weight sections. `WeightHistoryView` and
/// `WeightLogButton` are owned by the events agent (exact API:
/// `init(petID: String)` with the container from the environment) and are
/// referenced directly — a missing definition fails the build until that
/// change lands (reported to the merger).
struct PetDetailView: View {
    private let petID: String
    @EnvironmentObject var container: AppContainer

    init(petID: String) {
        self.petID = petID
    }

    var body: some View {
        PetDetailBodyView(vm: PetDetailViewModel(store: container.localStore), petID: petID)
    }
}

/// The state-owning detail body (same pattern as `PetsViewBody`).
private struct PetDetailBodyView: View {
    @StateObject var vm: PetDetailViewModel
    private let petID: String

    init(vm: PetDetailViewModel, petID: String) {
        _vm = StateObject(wrappedValue: vm)
        self.petID = petID
    }

    var body: some View {
        List {
            if let pet = vm.pet {
                Section {
                    ListRow(title: pet.name, icon: "pawprint", subtitle: subtitle(for: pet))
                }
            }
            Section(L10n.petDetailWeight.text) {
                WeightHistoryView(petID: petID)
                WeightLogButton(petID: petID)
            }
            Section(L10n.petDetailEvents.text) {
                if vm.events.isEmpty {
                    Text(L10n.timelineEmpty.text)
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(vm.events, id: \.id) { event in
                        ListRow(title: event.title, icon: "list.bullet", subtitle: event.occurredAt)
                    }
                }
            }
            Section(L10n.petDetailCourses.text) {
                if vm.courses.isEmpty {
                    Text(L10n.medsEmpty.text)
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(vm.courses, id: \.id) { course in
                        ListRow(title: course.title, icon: "pill", subtitle: course.occurredAt)
                    }
                }
            }
            Section(L10n.petDetailDocuments.text) {
                if vm.documents.isEmpty {
                    Text(L10n.docsEmpty.text)
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(vm.documents, id: \.id) { document in
                        ListRow(title: document.title, icon: "doc", subtitle: nil)
                    }
                }
            }
        }
        .navigationTitle(vm.pet?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await vm.load(petID: petID)
        }
    }

    private func subtitle(for pet: PetRecord) -> String? {
        let species: String = switch pet.species {
        case "dog": L10n.petsSpeciesDog.text
        case "cat": L10n.petsSpeciesCat.text
        default: L10n.petsSpeciesOther.text
        }
        guard let birthdate = pet.birthdate, birthdate.count >= 4 else { return species }
        return "\(species) · \(String(birthdate.prefix(4)))"
    }
}
