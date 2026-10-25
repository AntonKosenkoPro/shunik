// swiftlint:disable file_length
import Testing
import Foundation
@testable import Shunik

/// Documents §6.4: relay URL/confirm methods (`MockAPIClient`), byte
/// transfer (`DocumentTransferService` with `URLProtocolStub`-backed
/// sessions), and library view-model behavior (real `LocalStore`).
@MainActor
@Suite("DocumentTransfer")
struct DocumentTransferTests {

    // MARK: - Doubles

    /// Scriptable `SyncRelay`: offline everywhere except the transfer
    /// surface, which each test scripts.
    private final class ScriptRelay: SyncRelay, @unchecked Sendable {
        var uploadResult: Result<URL, Error>?
        var confirmResult: Result<DocumentRecord, Error>?
        var downloadResult: Result<URL, Error>?
        var uploadCalls: [String] = []
        var confirmCalls: [String] = []
        var downloadCalls: [String] = []

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
        func updateDocument(id: String, body: DocumentUpdateBody) async throws -> DocumentRecord {
            throw APIError.offline
        }
        func deleteDocument(id: String) async throws { throw APIError.offline }
        func listDeletions(since: String?) async throws -> DeletionListResponse { throw APIError.offline }

        func uploadURL(id: String) async throws -> URL {
            uploadCalls.append(id)
            switch uploadResult {
            case .success(let url): return url
            case .failure(let error): throw error
            case .none: throw APIError.offline
            }
        }

        func confirmUpload(id: String) async throws -> DocumentRecord {
            confirmCalls.append(id)
            switch confirmResult {
            case .success(let record): return record
            case .failure(let error): throw error
            case .none: throw APIError.offline
            }
        }

        func downloadURL(id: String) async throws -> URL {
            downloadCalls.append(id)
            switch downloadResult {
            case .success(let url): return url
            case .failure(let error): throw error
            case .none: throw APIError.offline
            }
        }
    }

    // MARK: - Fixtures

    private func sampleDoc(
        id: String = "doc-1",
        title: String = "Lab results",
        filename: String = "labs.pdf",
        mime: String = "application/pdf",
        petIDs: [String] = ["pet-1"],
        ready: Bool = false
    ) -> DocumentRecord {
        DocumentRecord(
            id: id, householdID: "hh-1", title: title, mime: mime,
            sizeBytes: 1234, filename: filename, blobKey: "hh-1/\(id)",
            ready: ready, extractedText: "", petIDs: petIDs,
            createdAt: "2026-10-26T07:00:00.100Z", updatedAt: "2026-10-26T07:00:00.100Z",
            updatedBy: "user-1"
        )
    }

    private func samplePet(id: String, name: String) -> PetRecord {
        PetRecord(
            id: id, householdID: "hh-1", name: name, species: "cat",
            birthdate: nil, notes: "",
            createdAt: "2026-10-26T11:00:00.100Z",
            updatedAt: "2026-10-26T12:00:00.100Z", updatedBy: "u1"
        )
    }

    private func tempFile(contents: String = "bytes") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func uniqueHost(path: String) -> URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: "https://cdn-\(UUID().uuidString.lowercased()).test/\(path)")!
    }

    private func makeStack(relay: ScriptRelay) throws -> (
        LocalStore, UndoBufferStore, SyncController, DocumentTransferService, DocumentsViewModel
    ) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("docs.db")
        let store = try LocalStore(url: url, householdID: "hh-docs")
        let undo = UndoBufferStore(store: store)
        let controller = SyncController(
            store: store,
            connectivity: MockConnectivity(connected: true)
        ) { "u1" }
        controller.relay = relay
        let transfer = DocumentTransferService(relay: relay, session: URLProtocolStub.makeSession())
        let vm = DocumentsViewModel(
            store: store, undo: undo, sync: controller,
            sessionUserID: "u1", transfer: transfer
        )
        return (store, undo, controller, transfer, vm)
    }

    // MARK: - Relay: URL decode

    @Test("uploadURL and downloadURL decode the presigned envelopes")
    func relayDecodesPresignedURLs() async throws {
        let repo = SyncRelayRepository(client: {
            let mock = MockAPIClient()
            mock.sendRawHandler = { endpoint in
                if endpoint.path.hasSuffix("upload-url") {
                    return (
                        Data("{\"upload_url\":\"https://cdn.test/put\",\"expires_at\":\"2026-10-26T13:00:00.100Z\"}".utf8),
                        200
                    )
                }
                return (
                    Data("{\"download_url\":\"https://cdn.test/get\",\"expires_at\":\"2026-10-26T13:00:00.100Z\"}".utf8),
                    200
                )
            }
            return mock
        }())
        let put = try await repo.uploadURL(id: "doc-1")
        #expect(put.absoluteString == "https://cdn.test/put")
        let get = try await repo.downloadURL(id: "doc-1")
        #expect(get.absoluteString == "https://cdn.test/get")
    }

    @Test("upload/download URL calls hit the transfer endpoints with auth")
    func relayTransferPaths() async throws {
        let mock = MockAPIClient()
        mock.sendRawHandler = { endpoint in
            let key = endpoint.path.hasSuffix("upload-url") ? "upload_url" : "download_url"
            return (Data("{\"\(key)\":\"https://cdn.test/x\",\"expires_at\":\"2026-10-26T13:00:00.100Z\"}".utf8), 200)
        }
        let repo = SyncRelayRepository(client: mock)
        _ = try await repo.uploadURL(id: "doc-1")
        _ = try await repo.downloadURL(id: "doc-1")
        #expect(mock.received.map(\.path) == [
            "/api/v1/documents/doc-1/upload-url",
            "/api/v1/documents/doc-1/download-url",
        ])
        #expect(mock.received.map(\.method) == [.get, .get])
        for endpoint in mock.received {
            #expect(endpoint.requiresAuth)
        }
    }

    @Test("confirmUpload decodes the ready record on 200")
    func relayConfirmDecodes() async throws {
        let mock = MockAPIClient()
        let ready = sampleDoc(ready: true)
        mock.sendRawHandler = { _ in (try JSONEncoder().encode(ready), 200) }
        let repo = SyncRelayRepository(client: mock)
        let result = try await repo.confirmUpload(id: "doc-1")
        #expect(result == ready && result.ready)
        #expect(mock.received.first?.path == "/api/v1/documents/doc-1/confirm")
        #expect(mock.received.first?.method == .post)
    }

    @Test("confirmUpload maps 409 upload_incomplete to a plain APIError")
    func relayConfirmIncomplete() async throws {
        // Tuple path (fake client): envelope decoded, never a ConflictError.
        let tupleMock = MockAPIClient()
        tupleMock.sendRawHandler = { _ in
            (TestFactories.makeErrorResponse(code: "upload_incomplete", message: "Upload has not completed yet"), 409)
        }
        let tupleRepo = SyncRelayRepository(client: tupleMock)
        do {
            _ = try await tupleRepo.confirmUpload(id: "doc-1")
            Issue.record("Expected upload_incomplete")
        } catch let api as APIError {
            #expect(api.code == "upload_incomplete")
        } catch {
            Issue.record("Wrong error type: \(error) — must be a plain APIError, never ConflictError")
        }

        // Production path (real APIClient throws the envelope): rethrown as-is.
        let thrownMock = MockAPIClient()
        thrownMock.sendRawHandler = { _ in
            throw APIError.server(code: "upload_incomplete", message: "Upload has not completed yet")
        }
        let thrownRepo = SyncRelayRepository(client: thrownMock)
        do {
            _ = try await thrownRepo.confirmUpload(id: "doc-1")
            Issue.record("Expected upload_incomplete")
        } catch let api as APIError {
            #expect(api.code == "upload_incomplete")
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    // MARK: - Transfer service

    @Test("upload PUTs bytes then confirms")
    func uploadPutsAndConfirms() async throws {
        let relay = ScriptRelay()
        let putURL = uniqueHost(path: "put")
        relay.uploadResult = .success(putURL)
        relay.confirmResult = .success(sampleDoc(ready: true))
        URLProtocolStub.stub(data: Data(), statusCode: 200, for: putURL)

        let transfer = DocumentTransferService(relay: relay, session: URLProtocolStub.makeSession())
        try await transfer.upload(documentID: "doc-1", fileURL: tempFile(), mime: "application/pdf")
        #expect(relay.uploadCalls == ["doc-1"])
        #expect(relay.confirmCalls == ["doc-1"])
    }

    @Test("upload maps confirm 409 to TransferError.notUploaded")
    func uploadIncompleteMaps() async throws {
        let relay = ScriptRelay()
        let putURL = uniqueHost(path: "put")
        relay.uploadResult = .success(putURL)
        relay.confirmResult = .failure(APIError.server(code: "upload_incomplete", message: "pending"))
        URLProtocolStub.stub(data: Data(), statusCode: 200, for: putURL)

        let transfer = DocumentTransferService(relay: relay, session: URLProtocolStub.makeSession())
        do {
            try await transfer.upload(documentID: "doc-1", fileURL: tempFile(), mime: "application/pdf")
            Issue.record("Expected notUploaded")
        } catch let transferError as TransferError {
            #expect(transferError == .notUploaded)
        }
    }

    @Test("upload maps a failed PUT to TransferError.transport")
    func uploadFailedPutMaps() async throws {
        let relay = ScriptRelay()
        let putURL = uniqueHost(path: "put")
        relay.uploadResult = .success(putURL)
        URLProtocolStub.stub(data: Data(), statusCode: 500, for: putURL)

        let transfer = DocumentTransferService(relay: relay, session: URLProtocolStub.makeSession())
        do {
            try await transfer.upload(documentID: "doc-1", fileURL: tempFile(), mime: "application/pdf")
            Issue.record("Expected transport")
        } catch let transferError as TransferError {
            #expect(transferError == .transport)
        }
        #expect(relay.confirmCalls.isEmpty)
    }

    @Test("download caches bytes and the second call skips the network")
    func downloadCaches() async throws {
        let relay = ScriptRelay()
        let getURL = uniqueHost(path: "get")
        relay.downloadResult = .success(getURL)
        URLProtocolStub.stub(data: Data("cached-bytes".utf8), statusCode: 200, for: getURL)

        let docID = "doc-\(UUID().uuidString.lowercased())"
        let transfer = DocumentTransferService(relay: relay, session: URLProtocolStub.makeSession())
        let doc = sampleDoc(id: docID)
        let first = try await transfer.download(document: doc)
        #expect(try String(contentsOf: first, encoding: .utf8) == "cached-bytes")
        #expect(relay.downloadCalls == [docID])

        // Drop every stub: a network hit would now fail, proving the cache.
        URLProtocolStub.clear()
        let second = try await transfer.download(document: doc)
        #expect(second == first)
        #expect(relay.downloadCalls == [docID])
        #expect(transfer.cachedFile(documentID: docID, filename: doc.filename) == first)
    }

    @Test("cachedFile is nil when nothing is cached")
    func cachedFileMissing() async throws {
        let relay = ScriptRelay()
        let transfer = DocumentTransferService(relay: relay, session: URLProtocolStub.makeSession())
        #expect(transfer.cachedFile(documentID: "missing-\(UUID().uuidString)", filename: "x.pdf") == nil)
    }

    // MARK: - View model: filter/search/counts

    @Test("pet filter includes shared docs under each linked pet")
    func petFilterSharedOverlap() async throws {
        let relay = ScriptRelay()
        let (store, _, _, _, vm) = try makeStack(relay: relay)
        _ = try await store.createPet(samplePet(id: "pet-1", name: "Barsik"), updatedBy: "u1")
        _ = try await store.createPet(samplePet(id: "pet-2", name: "Murzik"), updatedBy: "u1")
        _ = try await store.createDocument(sampleDoc(id: "doc-a", petIDs: ["pet-1"]), updatedBy: "u1")
        _ = try await store.createDocument(sampleDoc(id: "doc-b", petIDs: ["pet-1", "pet-2"]), updatedBy: "u1")
        await vm.load()

        vm.selectedPetID = "pet-2"
        #expect(vm.filtered.map(\.id) == ["doc-b"])
        vm.selectedPetID = "pet-1"
        #expect(Set(vm.filtered.map(\.id)) == ["doc-a", "doc-b"])
        vm.selectedPetID = nil
        #expect(vm.filtered.count == 2)

        // Counts overlap by design; the All row dedupes.
        #expect(vm.count(for: "pet-1") == 2)
        #expect(vm.count(for: "pet-2") == 1)
        #expect(vm.totalUnique == 2)
    }

    @Test("search matches the title only, case-insensitively")
    func searchTitleOnly() async throws {
        let relay = ScriptRelay()
        let (store, _, _, _, vm) = try makeStack(relay: relay)
        _ = try await store.createDocument(
            sampleDoc(id: "doc-a", title: "Lab Report", filename: "labs.pdf"), updatedBy: "u1"
        )
        _ = try await store.createDocument(
            sampleDoc(id: "doc-b", title: "Vet Passport", filename: "passport.pdf"), updatedBy: "u1"
        )
        await vm.load()

        vm.searchText = "lab"
        #expect(vm.filtered.map(\.id) == ["doc-a"])
        vm.searchText = "VET"
        #expect(vm.filtered.map(\.id) == ["doc-b"])
        // Filename-only match proves title-only search.
        vm.searchText = "passport.pdf"
        #expect(vm.filtered.isEmpty)
    }

    // MARK: - View model: mutations

    @Test("delete buffers the snapshot then removes the local row")
    func deleteBuffersThenRemoves() async throws {
        let relay = ScriptRelay()
        let (store, _, _, _, vm) = try makeStack(relay: relay)
        let stored = try await store.createDocument(sampleDoc(), updatedBy: "u1")
        await vm.load()
        #expect(vm.filtered.count == 1)

        await vm.delete(stored)
        #expect(try await store.getDocument(id: stored.id) == nil)
        #expect(try await store.bufferedDeletions().count == 1)
        #expect(vm.filtered.isEmpty)
        #expect(vm.errorMessage == nil)
    }

    @Test("rename persists the title")
    func renamePersists() async throws {
        let relay = ScriptRelay()
        let (store, _, _, _, vm) = try makeStack(relay: relay)
        let stored = try await store.createDocument(sampleDoc(title: "Old"), updatedBy: "u1")
        await vm.load()

        await vm.rename(stored, to: "New")
        #expect(try await store.getDocument(id: stored.id)?.title == "New")
    }

    @Test("pet-link edit replaces the set wholesale")
    func petLinksReplace() async throws {
        let relay = ScriptRelay()
        let (store, _, _, _, vm) = try makeStack(relay: relay)
        let stored = try await store.createDocument(sampleDoc(petIDs: ["pet-1"]), updatedBy: "u1")
        await vm.load()

        await vm.updatePets(stored, petIDs: ["pet-2", "pet-3"])
        #expect(try await store.getDocument(id: stored.id)?.petIDs == ["pet-2", "pet-3"])
    }

    // MARK: - View model: retry

    @Test("retryUpload succeeds from staged bytes and clears the badge")
    func retryUploadSuccess() async throws {
        let relay = ScriptRelay()
        let putURL = uniqueHost(path: "put")
        relay.uploadResult = .success(putURL)
        relay.confirmResult = .success(sampleDoc(ready: true))
        URLProtocolStub.stub(data: Data(), statusCode: 200, for: putURL)

        let (store, _, _, transfer, vm) = try makeStack(relay: relay)
        let docID = "doc-\(UUID().uuidString.lowercased())"
        let stored = try await store.createDocument(sampleDoc(id: docID), updatedBy: "u1")
        try transfer.stage(documentID: docID, filename: stored.filename, fileURL: tempFile())
        await vm.load()
        #expect(vm.needsUpload(stored))

        await vm.retryUpload(stored)
        #expect(relay.confirmCalls == [docID])
        #expect(vm.errorMessage == nil)
        #expect(!vm.uploadFailed(stored))
    }

    @Test("retryUpload without staged bytes marks the row failed")
    func retryUploadNoBytes() async throws {
        let relay = ScriptRelay()
        let (_, _, _, _, vm) = try makeStack(relay: relay)
        let stored = sampleDoc(id: "doc-\(UUID().uuidString.lowercased())")
        // No store row and no staged bytes: failure badge + message.
        await vm.retryUpload(stored)
        #expect(vm.uploadFailed(stored))
        #expect(vm.errorMessage != nil)
        #expect(relay.uploadCalls.isEmpty)
    }

    @Test("retryUpload maps confirm 409 to the failed badge")
    func retryUploadIncomplete() async throws {
        let relay = ScriptRelay()
        let putURL = uniqueHost(path: "put")
        relay.uploadResult = .success(putURL)
        relay.confirmResult = .failure(APIError.server(code: "upload_incomplete", message: "pending"))
        URLProtocolStub.stub(data: Data(), statusCode: 200, for: putURL)

        let (store, _, _, transfer, vm) = try makeStack(relay: relay)
        let docID = "doc-\(UUID().uuidString.lowercased())"
        let stored = try await store.createDocument(sampleDoc(id: docID), updatedBy: "u1")
        try transfer.stage(documentID: docID, filename: stored.filename, fileURL: tempFile())
        await vm.load()

        await vm.retryUpload(stored)
        #expect(vm.uploadFailed(stored))
        #expect(vm.errorMessage != nil)
    }
}
