import SwiftUI

/// Pet list (§6.1): the household's pets with add, edit, and swipe-to-delete.
/// Parameterless for shell use (the view model is built from the environment
/// container on first appearance); `init(vm:)` injects a model for tests and
/// previews. No pet picker here — the adaptive rule lives in `PetScope` for
/// the list view models (Timeline/Meds/Docs). Silent reload after delete: no
/// toast infrastructure exists.
struct PetsView: View {
    @EnvironmentObject var container: AppContainer

    private let injectedVM: PetsViewModel?

    init() {
        injectedVM = nil
    }

    init(vm: PetsViewModel) {
        injectedVM = vm
    }

    var body: some View {
        Group {
            if let injectedVM {
                PetsViewBody(vm: injectedVM)
            } else {
                PetsViewBody(vm: PetsViewModel(
                    store: container.localStore,
                    undo: container.undoBuffer,
                    sync: container.syncController
                ) { [weak container] in
                    guard let session = container?.sessionStore.state,
                          case let .signedIn(current) = session
                    else { return nil }
                    return current.id
                })
            }
        }
    }
}

/// The state-owning list body: created once per `PetsView` identity, so the
/// shell-built view model above is kept across renders (later constructions
/// are discarded by `StateObject`).
private struct PetsViewBody: View {
    @EnvironmentObject var container: AppContainer
    @StateObject var vm: PetsViewModel

    @State private var showingAdd = false
    @State private var editingTarget: PetEditTarget?
    @State private var pendingDelete: PetRecord?

    init(vm: PetsViewModel) {
        _vm = StateObject(wrappedValue: vm)
    }

    private var sessionUserID: String {
        if case let .signedIn(current) = container.sessionStore.state {
            return current.id
        }
        return ""
    }

    var body: some View {
        Group {
            if vm.pets.isEmpty {
                emptyState
            } else {
                petList
            }
        }
        .navigationTitle(L10n.petsTitle.text)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("PetsAddButton")
                .accessibilityLabel(L10n.petsAdd.text)
            }
        }
        .sheet(isPresented: $showingAdd) {
            PetFormView(store: container.localStore, existing: nil, updatedBy: sessionUserID) {
                Task { await vm.load() }
            }
        }
        .sheet(item: $editingTarget) { target in
            PetFormView(store: container.localStore, existing: target.pet, updatedBy: sessionUserID) {
                Task { await vm.load() }
            }
        }
        .alert(L10n.petsDeleteTitle.text, isPresented: deleteAlertBinding) {
            Button(L10n.commonDelete.text, role: .destructive) {
                if let pendingDelete {
                    Task { await vm.delete(pendingDelete) }
                }
            }
            Button(L10n.commonCancel.text, role: .cancel) {}
        } message: {
            Text(L10n.petsDeleteMessage.text)
        }
        .task {
            await vm.load()
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var emptyState: some View {
        VStack(spacing: Theme.spacingMedium) {
            Text(L10n.petsEmpty.text)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(L10n.petsEmptyHint.text)
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button(L10n.petsAdd.text) {
                showingAdd = true
            }
        }
        .padding()
    }

    private var petList: some View {
        List {
            ForEach(vm.pets, id: \.id) { pet in
                NavigationLink {
                    PetDetailView(petID: pet.id)
                } label: {
                    ListRow(title: pet.name, icon: "pawprint", subtitle: subtitle(for: pet))
                }
                .accessibilityIdentifier("PetRow-\(pet.id)")
                .swipeActions(edge: .leading) {
                    Button {
                        editingTarget = PetEditTarget(pet: pet)
                    } label: {
                        Label(L10n.commonEdit.text, systemImage: "pencil")
                    }
                    .tint(Theme.accentPrimary)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingDelete = pet
                    } label: {
                        Label(L10n.commonDelete.text, systemImage: "trash")
                    }
                }
            }
        }
    }

    /// Subtitle: species plus the birth year when known (no date math — the
    /// record carries a plain `yyyy-MM-dd` string).
    private func subtitle(for pet: PetRecord) -> String? {
        let species = speciesLabel(for: pet.species)
        guard let birthdate = pet.birthdate, birthdate.count >= 4 else { return species }
        return "\(species) · \(String(birthdate.prefix(4)))"
    }

    private func speciesLabel(for species: String) -> String {
        switch species {
        case "dog": return L10n.petsSpeciesDog.text
        case "cat": return L10n.petsSpeciesCat.text
        default: return L10n.petsSpeciesOther.text
        }
    }
}

/// Sheet target for the edit form (`sheet(item:)` needs `Identifiable`;
/// kept local so no shared model gains a conformance other agents might
/// also add).
private struct PetEditTarget: Identifiable {
    let pet: PetRecord
    var id: String { pet.id }
}
