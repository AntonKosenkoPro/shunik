import SwiftUI
import UniformTypeIdentifiers

/// Document create sheet (§6.4).
///
/// MERGER NOTE: wire as `.sheet` from `DocumentsView`'s Add button as
/// `DocumentFormView(pets:transfer:store:sessionUserID:preselected:onSaved:)` —
/// `pets` is the household pet list (for the multi-select), `preselected`
/// preselects the current filter pet, `store`/`sessionUserID` persist the
/// metadata row, `transfer` PUTs the bytes, and `onSaved` reloads the parent
/// list + triggers sync. `transfer` is the same `DocumentTransferService`
/// instance the parent view model holds so the cache layout matches
/// `retryUpload`.
///
/// Offline path: the metadata row is queued in the outbox by
/// `LocalStore.createDocument` and the picked bytes are staged into the
/// transfer cache, so the row shows the `docs.waitingUpload` badge until
/// `retryUpload` completes the PUT.
struct DocumentFormView: View {
    private let pets: [PetRecord]
    private let transfer: DocumentTransferService
    private let store: LocalStore
    private let sessionUserID: String
    private let onSaved: () -> Void

    @State private var title = ""
    @State private var selectedPetIDs: Set<String>
    @State private var pickedName: String?
    @State private var pickedType: UTType?
    @State private var stagedURL: URL?
    @State private var isImporting = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    @Environment(\.dismiss)
    private var dismiss

    init(
        pets: [PetRecord],
        transfer: DocumentTransferService,
        store: LocalStore,
        sessionUserID: String,
        preselected: [String] = [],
        onSaved: @escaping () -> Void = {}
    ) {
        self.pets = pets
        self.transfer = transfer
        self.store = store
        self.sessionUserID = sessionUserID
        self.onSaved = onSaved
        _selectedPetIDs = State(initialValue: Set(preselected))
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && stagedURL != nil && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.docsTitleLabel.text) {
                    TextField(L10n.docsTitleLabel.text, text: $title)
                        .accessibilityIdentifier("DocumentTitleField")
                }
                Section(L10n.docsLinkedPets.text) {
                    if pets.isEmpty {
                        Text(L10n.docsNoPets.text)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(pets, id: \.id) { pet in
                        Button {
                            if selectedPetIDs.contains(pet.id) {
                                selectedPetIDs.remove(pet.id)
                            } else {
                                selectedPetIDs.insert(pet.id)
                            }
                        } label: {
                            HStack {
                                Text(pet.name)
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                if selectedPetIDs.contains(pet.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.accentPrimary)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button(pickedName ?? L10n.docsAdd.text) {
                        isImporting = true
                    }
                    .accessibilityIdentifier("DocumentPickButton")
                    if isSaving {
                        HStack {
                            ProgressView()
                            Text(L10n.docsUploading.text)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    if let errorMessage {
                        ErrorBanner(message: errorMessage, accessibilityId: "DocumentFormError")
                    }
                }
            }
            .navigationTitle(L10n.docsAdd.text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.commonCancel.text) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.commonSave.text) { Task { await save() } }
                        .disabled(!canSave)
                        .accessibilityIdentifier("DocumentSaveButton")
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [UTType.pdf, UTType.image, UTType.plainText]
            ) { result in
                do {
                    let url = try result.get()
                    stagePickedFile(from: url)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - File staging

    /// Copies the picked file into a temp URL (the importer URL is
    /// security-scoped and short-lived).
    private func stagePickedFile(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let ext = url.pathExtension
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext.isEmpty ? "bin" : ext)
            try FileManager.default.copyItem(at: url, to: temp)
            stagedURL = temp
            pickedName = url.lastPathComponent
            pickedType = UTType(filenameExtension: ext)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Save

    private func save() async {
        guard let stagedURL, canSave else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let values = try FileManager.default.attributesOfItem(atPath: stagedURL.path)
            let size = (values[.size] as? Int64) ?? 0
            let mime = pickedType?.preferredMIMEType ?? "application/octet-stream"
            let filename = pickedName ?? stagedURL.lastPathComponent
            // blob_key is server-assigned (DocumentInput has no blob_key —
            // the backend returns it on create); the empty string is
            // overwritten from the confirmed/pulled row.
            let record = DocumentRecord(
                id: UUID().uuidString.lowercased(),
                householdID: await store.boundHouseholdID ?? "",
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                mime: mime,
                sizeBytes: size,
                filename: filename,
                blobKey: "",
                ready: false,
                extractedText: "",
                petIDs: Array(selectedPetIDs),
                createdAt: "",
                updatedAt: "",
                updatedBy: ""
            )
            let created = try await store.createDocument(record, updatedBy: sessionUserID)
            do {
                try await transfer.upload(documentID: created.id, fileURL: stagedURL, mime: mime)
            } catch {
                // Bytes stay staged in the cache so retryUpload can PUT them
                // without the original picked file; the row badge shows
                // waiting until then.
                try? transfer.stage(documentID: created.id, filename: filename, fileURL: stagedURL)
            }
            try? FileManager.default.removeItem(at: stagedURL)
            self.stagedURL = nil
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#if DEBUG
#Preview("Document Form") {
    // Preview-only doubles: the preview never saves.
    DocumentFormView(
        pets: [],
        transfer: DocumentTransferService(relay: PreviewOfflineRelay()),
        store: LocalStore(),
        sessionUserID: "preview"
    )
}

/// Preview-only offline relay (DEBUG only — never ships in test targets).
private struct PreviewOfflineRelay: SyncRelay {
    func fetchHousehold() async throws -> HouseholdWithMembers { throw APIError.offline }
    func listPets(since: String?) async throws -> PetListResponse { throw APIError.offline }
    func createPet(_ pet: PetRecord) async throws -> PetRecord { throw APIError.offline }
    func updatePet(id: String, body: PetUpdateBody) async throws -> PetRecord { throw APIError.offline }
    func deletePet(id: String) async throws { throw APIError.offline }
    func listEvents(since: String?, petID: String?) async throws -> EventListResponse { throw APIError.offline }
    func createEvent(_ event: EventRecord) async throws -> EventRecord { throw APIError.offline }
    func updateEvent(id: String, body: EventUpdateBody) async throws -> EventRecord { throw APIError.offline }
    func deleteEvent(id: String) async throws { throw APIError.offline }
    func listIntakes(since: String?, courseID: String?) async throws -> IntakeListResponse { throw APIError.offline }
    func createIntake(_ intake: IntakeRecord) async throws -> IntakeRecord { throw APIError.offline }
    func updateIntake(id: String, body: IntakeUpdateBody) async throws -> IntakeRecord { throw APIError.offline }
    func deleteIntake(id: String) async throws { throw APIError.offline }
    func listDocuments(since: String?) async throws -> DocumentListResponse { throw APIError.offline }
    func createDocument(_ doc: DocumentRecord) async throws -> DocumentRecord { throw APIError.offline }
    func updateDocument(id: String, body: DocumentUpdateBody) async throws -> DocumentRecord { throw APIError.offline }
    func deleteDocument(id: String) async throws { throw APIError.offline }
    func listDeletions(since: String?) async throws -> DeletionListResponse { throw APIError.offline }
}
#endif
