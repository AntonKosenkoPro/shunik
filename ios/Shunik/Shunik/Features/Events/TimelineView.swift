import SwiftUI

/// The §6.2 events timeline root. Parameterless: it resolves the composition
/// root from the environment and owns its view model from there. Shows the
/// scope picker only for multi-pet households (single-pet homes filter to
/// that pet with no picker, no "All", and no per-row pet prefix).
struct TimelineView: View {
    @EnvironmentObject var container: AppContainer

    var body: some View {
        let sessionStore = container.sessionStore
        TimelineContentView(vm: TimelineViewModel(
            store: container.localStore,
            undo: container.undoBuffer,
            sync: container.syncController
        ) {
            if case let .signedIn(current) = sessionStore.state {
                return current.id
            }
            return nil
        })
    }
}

/// The state-owning timeline body (`init(vm:)` + `StateObject` pattern, like
/// the shell views). Split from the parameterless root so previews and
/// embedders can inject a view model.
struct TimelineContentView: View {
    @StateObject var vm: TimelineViewModel
    @State private var showingAdd = false
    @State private var editingEvent: EventRecord?
    @State private var pendingDelete: EventRecord?
    @State private var isShowingDeleteConfirm = false

    init(vm: TimelineViewModel) {
        _vm = StateObject(wrappedValue: vm)
    }

    var body: some View {
        List {
            if vm.showsScopeChrome {
                Section {
                    Picker(L10n.petsTitle.text, selection: scopeBinding) {
                        Text(L10n.commonAll.text).tag(nil as String?)
                        ForEach(vm.pets, id: \.id) { pet in
                            Text(pet.name).tag(pet.id as String?)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            if let errorMessage = vm.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(Theme.danger)
                }
            }
            if vm.events.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: Theme.spacingSmall) {
                        Text(L10n.timelineEmpty.text)
                            .foregroundStyle(Theme.textPrimary)
                        Text(L10n.timelineEmptyHint.text)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            } else {
                Section {
                    ForEach(vm.events, id: \.id) { event in
                        row(for: event)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if Self.isEditableKind(event.kind) {
                                    editingEvent = event
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingDelete = event
                                    isShowingDeleteConfirm = true
                                } label: {
                                    Label(L10n.commonDelete.text, systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle(L10n.timelineTitle.text)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Label(L10n.eventAdd.text, systemImage: "plus")
                }
                .disabled(vm.pets.isEmpty)
            }
        }
        .task {
            await vm.load()
        }
        .sheet(isPresented: $showingAdd, onDismiss: { Task { await vm.load() } }, content: {
            if let petID = vm.effectivePetID ?? vm.pets.first?.id {
                EventFormView(eventID: nil, petID: petID, kind: "vaccination")
            }
        })
        .sheet(isPresented: editBinding, onDismiss: { Task { await vm.load() } }, content: {
            if let event = editingEvent {
                EventFormView(eventID: event.id, petID: event.petID, kind: event.kind)
            }
        })
        .alert(L10n.eventDeleteTitle.text, isPresented: $isShowingDeleteConfirm) {
            Button(L10n.commonDelete.text, role: .destructive) {
                if let event = pendingDelete {
                    pendingDelete = nil
                    Task { await vm.delete(event) }
                }
            }
            Button(L10n.commonCancel.text, role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text(L10n.eventDeleteMessage.text)
        }
    }

    private var scopeBinding: Binding<String?> {
        Binding(
            get: { vm.effectivePetID },
            set: { vm.selectedPetID = $0 }
        )
    }

    private var editBinding: Binding<Bool> {
        Binding(
            get: { editingEvent != nil },
            set: { if !$0 { editingEvent = nil } }
        )
    }

    private func row(for event: EventRecord) -> some View {
        HStack(spacing: Theme.spacingSmall) {
            Image(systemName: event.timelineKindIcon)
                .foregroundStyle(Theme.accentPrimary)
                .frame(minWidth: Theme.minTapArea, minHeight: Theme.minTapArea)
            VStack(alignment: .leading, spacing: Theme.spacingExtraSmall) {
                Text(event.title)
                    .foregroundStyle(Theme.textPrimary)
                Text(summary(for: event))
                    .foregroundStyle(Theme.textSecondary)
                Text(event.timelineDateText)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func summary(for event: EventRecord) -> String {
        guard vm.showsScopeChrome,
              let name = vm.petNamesByID[event.petID]
        else {
            return event.timelineSummary
        }
        return "\(name) • \(event.timelineSummary)"
    }

    private static func isEditableKind(_ kind: String) -> Bool {
        kind == "vaccination" || kind == "grooming" || kind == "weight"
    }
}

#if DEBUG
#Preview("Timeline") {
    let container = AppContainer.production()
    NavigationStack {
        TimelineView()
            .environmentObject(container)
    }
}
#endif
