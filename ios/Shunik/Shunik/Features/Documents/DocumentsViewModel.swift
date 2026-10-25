import Foundation

/// Documents library state (§6.4): the household document list with
/// title-search and per-pet filtering, metadata edits, undo-buffered
/// deletes, and explicit upload retries.
///
/// Filtering rule: a document shows under every pet it links (shared /
/// multi-pet documents are included under each linked pet), so per-pet
/// counts overlap by design; the All row uses `totalUnique`. Search matches
/// the title only (case-insensitive, per spec).
///
/// Uploads are explicit-only: `load()` never attempts a PUT — rows with
/// `ready == false` show the waiting badge until `retryUpload` succeeds.
@MainActor
final class DocumentsViewModel: ObservableObject {
    @Published private(set) var documents: [DocumentRecord] = []
    @Published private(set) var pets: [PetRecord] = []
    @Published var searchText = ""
    @Published var selectedPetID: String?
    @Published private(set) var failedUploads: Set<String> = []
    @Published var errorMessage: String?

    private let store: LocalStore
    private let undo: UndoBufferStore
    private let sync: SyncController
    private let sessionUserID: String
    private let transfer: DocumentTransferService

    init(
        store: LocalStore,
        undo: UndoBufferStore,
        sync: SyncController,
        sessionUserID: String,
        transfer: DocumentTransferService
    ) {
        self.store = store
        self.undo = undo
        self.sync = sync
        self.sessionUserID = sessionUserID
        self.transfer = transfer
    }

    /// Reloads pets + documents from the store. Never uploads.
    func load() async {
        errorMessage = nil
        do {
            pets = try await store.listPets()
            documents = try await store.listDocuments()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// In-memory filter: title contains the search text (case-insensitive)
    /// and, when a pet is selected, the document links that pet.
    var filtered: [DocumentRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return documents.filter { doc in
            let matchesSearch = query.isEmpty || doc.title.lowercased().contains(query)
            let matchesPet = selectedPetID.map { doc.petIDs.contains($0) } ?? true
            return matchesSearch && matchesPet
        }
    }

    /// Documents linked to one pet. Shared documents count toward every
    /// linked pet (overlap by design).
    func count(for petID: String) -> Int {
        documents.filter { $0.petIDs.contains(petID) }.count
    }

    /// Documents in the library, deduped by id, for the All row.
    var totalUnique: Int {
        Set(documents.map(\.id)).count
    }

    /// Display name for a linked pet id, or nil when unknown.
    func petName(for id: String) -> String? {
        pets.first { $0.id == id }?.name
    }

    /// Whether the row needs an upload attempt (badge state). Ready rows
    /// show none; not-ready rows show waiting, or failed after a failed
    /// `retryUpload` attempt.
    func needsUpload(_ doc: DocumentRecord) -> Bool {
        !doc.ready
    }

    func uploadFailed(_ doc: DocumentRecord) -> Bool {
        failedUploads.contains(doc.id)
    }

    /// The cached bytes for a row, for the Share sheet.
    func cachedURL(_ doc: DocumentRecord) -> URL? {
        transfer.cachedFile(documentID: doc.id, filename: doc.filename)
    }

    /// Downloads (or returns cached) bytes for sharing. Sets `errorMessage`
    /// and returns nil on failure.
    func shareFile(for doc: DocumentRecord) async -> URL? {
        do {
            return try await transfer.download(document: doc)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Undo-buffered delete: buffers the snapshot first (crash between the
    /// steps leaves rows present AND restorable), removes the local row,
    /// reloads, and triggers sync.
    func delete(_ doc: DocumentRecord) async {
        do {
            try await undo.bufferDeletion(of: [(resource: .document, id: doc.id)])
            try await store.removeDocumentLocal(id: doc.id)
            await load()
            sync.trigger(userID: sessionUserID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Title-only metadata edit.
    func rename(_ doc: DocumentRecord, to title: String) async {
        await applyEdit(doc, title: title, petIDs: doc.petIDs)
    }

    /// Pet-link edit: replaces the link set wholesale.
    func updatePets(_ doc: DocumentRecord, petIDs: [String]) async {
        await applyEdit(doc, title: doc.title, petIDs: petIDs)
    }

    private func applyEdit(_ doc: DocumentRecord, title: String, petIDs: [String]) async {
        do {
            guard var current = try await store.getDocument(id: doc.id) else { return }
            current.title = title
            current.petIDs = petIDs
            _ = try await store.updateDocument(current, baseUpdatedAt: current.updatedAt, updatedBy: sessionUserID)
            await load()
            sync.trigger(userID: sessionUserID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Explicit upload retry from staged/cached bytes. Success clears the
    /// failure badge, reloads, and triggers sync; failure marks the row and
    /// surfaces `errorMessage`.
    func retryUpload(_ doc: DocumentRecord) async {
        guard let fileURL = transfer.cachedFile(documentID: doc.id, filename: doc.filename) else {
            failedUploads.insert(doc.id)
            errorMessage = L10n.docsUploadFailed.text
            return
        }
        do {
            try await transfer.upload(documentID: doc.id, fileURL: fileURL, mime: doc.mime)
            failedUploads.remove(doc.id)
            await load()
            sync.trigger(userID: sessionUserID)
        } catch {
            failedUploads.insert(doc.id)
            errorMessage = error.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }
}
