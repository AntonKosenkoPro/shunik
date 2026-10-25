import SwiftUI

/// Documents library root (§6.4): search + per-pet filter chips + the
/// document list with status badges, share, rename, pet-link editing,
/// undo-buffered delete, and the Add sheet.
///
/// MERGER NOTE: mount inside the owning tab's `NavigationStack` with
/// `.environmentObject(container)`,
/// `.environmentObject(container.sessionStore)`, and
/// `.environmentObject(container.syncController)` (the `ProfileView`
/// pattern). `DocumentsView()` takes no parameters — it builds its
/// `DocumentsViewModel` + `DocumentTransferService` from those objects on
/// first appearance. The Add sheet wires `DocumentFormView` (see its header
/// for the exact init). No auto-upload happens on appear: not-ready rows
/// show the waiting badge until the user retries.
struct DocumentsView: View {
    @EnvironmentObject var container: AppContainer
    @EnvironmentObject var session: SessionStore
    @EnvironmentObject var sync: SyncController

    @State private var vm: DocumentsViewModel?
    @State private var transfer: DocumentTransferService?

    init() {}

    var body: some View {
        Group {
            if let vm, let transfer {
                DocumentsContentView(
                    vm: vm,
                    transfer: transfer,
                    store: container.localStore,
                    sessionUserID: sessionUserID
                )
            } else {
                ProgressView()
                    .task { buildStack() }
            }
        }
        .navigationTitle(L10n.docsTitle.text)
    }

    private var sessionUserID: String {
        if case let .signedIn(current) = session.state { return current.id }
        return ""
    }

    @MainActor
    private func buildStack() {
        guard vm == nil, let relay = sync.relay else { return }
        let service = DocumentTransferService(relay: relay)
        transfer = service
        let model = DocumentsViewModel(
            store: container.localStore,
            undo: container.undoBuffer,
            sync: sync,
            sessionUserID: sessionUserID,
            transfer: service
        )
        vm = model
        Task { await model.load() }
    }
}

// MARK: - Content

private struct DocumentsContentView: View {
    @ObservedObject var vm: DocumentsViewModel
    let transfer: DocumentTransferService
    let store: LocalStore
    let sessionUserID: String

    @State private var isShowingAdd = false
    @State private var renamingDoc: DocumentRecord?
    @State private var renameText = ""
    @State private var editingPetsDoc: DocumentRecord?
    @State private var deletingDoc: DocumentRecord?
    @State private var shareURL: URL?
    @State private var isShowingShare = false
    @State private var isShareLoading = false

    var body: some View {
        VStack(spacing: 0) {
            searchField
            filterChips
            if let message = vm.errorMessage {
                HStack {
                    ErrorBanner(message: message, accessibilityId: "DocumentsErrorBanner")
                    Spacer()
                    Button(L10n.commonDone.text) { vm.clearError() }
                }
                .padding(.horizontal, Theme.screenHorizontalPadding)
            }
            if vm.filtered.isEmpty {
                emptyState
            } else {
                List(vm.filtered, id: \.id) { doc in
                    row(for: doc)
                }
                .listStyle(.plain)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("DocumentsAddButton")
                .accessibilityLabel(L10n.docsAdd.text)
            }
        }
        .sheet(isPresented: $isShowingAdd) {
            DocumentFormView(
                pets: vm.pets,
                transfer: transfer,
                store: store,
                sessionUserID: sessionUserID,
                preselected: vm.selectedPetID.map { [$0] } ?? []
            ) {
                Task {
                    await vm.load()
                }
            }
        }
        .sheet(item: $editingPetsDoc) { doc in
            PetLinkEditorView(doc: doc, pets: vm.pets) { petIDs in
                Task { await vm.updatePets(doc, petIDs: petIDs) }
            }
        }
        .alert(
            L10n.docsRename.text,
            isPresented: Binding(get: { renamingDoc != nil }, set: { if !$0 { renamingDoc = nil } }),
            presenting: renamingDoc
        ) { doc in
            TextField(L10n.docsTitleLabel.text, text: $renameText)
            Button(L10n.commonSave.text) {
                Task { await vm.rename(doc, to: renameText) }
            }
            Button(L10n.commonCancel.text, role: .cancel) {}
        }
        .alert(
            L10n.docsDeleteTitle.text,
            isPresented: Binding(get: { deletingDoc != nil }, set: { if !$0 { deletingDoc = nil } }),
            presenting: deletingDoc
        ) { doc in
            Button(L10n.commonDelete.text, role: .destructive) {
                Task { await vm.delete(doc) }
            }
            Button(L10n.commonCancel.text, role: .cancel) {}
        } message: { _ in
            Text(L10n.docsDeleteMessage.text)
        }
        .sheet(isPresented: $isShowingShare) {
            if let shareURL {
                ShareLink(item: shareURL)
                    .padding()
            }
        }
        .task {
            await vm.load()
        }
    }

    // MARK: - Search + filters

    private var searchField: some View {
        TextField(L10n.docsSearch.text, text: $vm.searchText)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("DocumentsSearchField")
            .padding(.horizontal, Theme.screenHorizontalPadding)
            .padding(.vertical, Theme.spacingSmall)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.spacingSmall) {
                chip(title: L10n.commonAll.text, count: vm.totalUnique, isSelected: vm.selectedPetID == nil) {
                    vm.selectedPetID = nil
                }
                ForEach(vm.pets, id: \.id) { pet in
                    chip(
                        title: pet.name,
                        count: vm.count(for: pet.id),
                        isSelected: vm.selectedPetID == pet.id
                    ) {
                        vm.selectedPetID = pet.id
                    }
                }
            }
            .padding(.horizontal, Theme.screenHorizontalPadding)
            .padding(.bottom, Theme.spacingSmall)
        }
    }

    private func chip(title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text("\(title) • \(count)")
                .font(.caption)
                .foregroundStyle(isSelected ? Theme.textOnAccent : Theme.textPrimary)
                .padding(.horizontal, Theme.spacingChip)
                .padding(.vertical, Theme.spacingSmall)
                .background(isSelected ? Theme.accentPrimary : Theme.backgroundSecondary)
                .clipShape(Capsule())
        }
    }

    // MARK: - Rows

    private func subtitle(for doc: DocumentRecord) -> String? {
        let names = doc.petIDs.compactMap { vm.petName(for: $0) }
        let pets = names.isEmpty ? L10n.docsNoPets.text : names.joined(separator: ", ")
        return "\(pets) • \(Self.sizeText(doc.sizeBytes))"
    }

    private func row(for doc: DocumentRecord) -> some View {
        ListRow(title: doc.title, icon: "doc", subtitle: subtitle(for: doc)) {
            HStack(spacing: Theme.spacingSmall) {
                if vm.needsUpload(doc) {
                    if vm.uploadFailed(doc) {
                        Button(L10n.commonRetry.text) {
                            Task { await vm.retryUpload(doc) }
                        }
                        .font(.caption)
                    }
                    Text(vm.uploadFailed(doc) ? L10n.docsUploadFailed.text : L10n.docsWaitingUpload.text)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                if isShareLoading {
                    ProgressView()
                } else {
                    Button {
                        Task { await share(doc) }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("DocumentShareButton-\(doc.id)")
                    .accessibilityLabel(L10n.commonShare.text)
                }
            }
        }
        .contextMenu {
            Button(L10n.docsRename.text) {
                renameText = doc.title
                renamingDoc = doc
            }
            Button(L10n.docsLinkedPets.text) {
                editingPetsDoc = doc
            }
            Button(L10n.commonDelete.text, role: .destructive) {
                deletingDoc = doc
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.spacingSmall) {
            Spacer()
            Text(L10n.docsEmpty.text)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(L10n.docsEmptyHint.text)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button(L10n.docsAdd.text) {
                isShowingAdd = true
            }
            .padding(.top, Theme.spacingSmall)
            Spacer()
        }
        .padding(.horizontal, Theme.screenHorizontalPadding)
    }

    // MARK: - Share

    private func share(_ doc: DocumentRecord) async {
        isShareLoading = true
        defer { isShareLoading = false }
        guard let url = await vm.shareFile(for: doc) else { return }
        shareURL = url
        isShowingShare = true
    }

    private static func sizeText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Pet-link editor

/// Wholesale pet-link editor: toggles the link set, saves via
/// `DocumentsViewModel.updatePets` (link set replaced wholesale).
private struct PetLinkEditorView: View {
    let doc: DocumentRecord
    let pets: [PetRecord]
    let onSave: ([String]) -> Void

    @State private var selected: Set<String>
    @Environment(\.dismiss)
    private var dismiss

    init(doc: DocumentRecord, pets: [PetRecord], onSave: @escaping ([String]) -> Void) {
        self.doc = doc
        self.pets = pets
        self.onSave = onSave
        _selected = State(initialValue: Set(doc.petIDs))
    }

    var body: some View {
        NavigationStack {
            List(pets, id: \.id) { pet in
                Button {
                    if selected.contains(pet.id) {
                        selected.remove(pet.id)
                    } else {
                        selected.insert(pet.id)
                    }
                } label: {
                    HStack {
                        Text(pet.name)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        if selected.contains(pet.id) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Theme.accentPrimary)
                        }
                    }
                }
            }
            .navigationTitle(L10n.docsLinkedPets.text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel.text) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.commonSave.text) {
                        onSave(Array(selected))
                        dismiss()
                    }
                }
            }
        }
    }
}

extension DocumentRecord: Identifiable {}

#if DEBUG
#Preview("Documents (empty)") {
    let container = AppContainer.production()
    return DocumentsView()
        .environmentObject(container)
        .environmentObject(container.sessionStore)
        .environmentObject(container.syncController)
}
#endif
