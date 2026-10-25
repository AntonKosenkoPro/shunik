import Foundation

/// Typed failures of the document byte transfer. Metadata errors propagate
/// as `APIError` untouched — only byte-movement outcomes map here.
enum TransferError: Error, Equatable, Sendable {
    /// `confirmUpload` returned 409 `upload_incomplete`: the PUT never
    /// landed at the blob key. Retry the upload later.
    case notUploaded
    /// The bytes could not be fetched from (or stored to) the CDN/cache:
    /// network failure, non-2xx PUT/GET, or a local file error.
    case transport
}

/// Moves document bytes between the CDN presigned URLs and the on-disk
/// cache (`Application Support/documents/<id>-<filename>`). Metadata
/// (`DocumentRecord`, pet links) stays in `LocalStore`/the relay — this
/// service only handles bytes.
///
/// `URLSession` is injectable so tests stub the CDN with `URLProtocolStub`;
/// `FileManager` is injectable for the same reason (defaults to `.default`).
@MainActor
final class DocumentTransferService {
    private let relay: any SyncRelay
    private let files: FileManager
    private let session: URLSession

    init(relay: any SyncRelay, files: FileManager = .default, session: URLSession = .shared) {
        self.relay = relay
        self.files = files
        self.session = session
    }

    /// PUTs the file at `fileURL` to the presigned upload URL, then confirms.
    /// A 409 `upload_incomplete` from confirm surfaces as
    /// `TransferError.notUploaded` (retry later); transport-level PUT
    /// failures surface as `TransferError.transport`; all other relay
    /// errors (`APIError`) propagate unchanged.
    func upload(documentID: String, fileURL: URL, mime: String) async throws {
        let target = try await relay.uploadURL(id: documentID)
        var request = URLRequest(url: target)
        request.httpMethod = "PUT"
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        let putResponse: URLResponse
        do {
            (_, putResponse) = try await session.upload(for: request, fromFile: fileURL)
        } catch {
            throw TransferError.transport
        }
        guard let http = putResponse as? HTTPURLResponse, 200 ... 299 ~= http.statusCode else {
            throw TransferError.transport
        }
        do {
            _ = try await relay.confirmUpload(id: documentID)
        } catch let api as APIError where api.code == "upload_incomplete" {
            throw TransferError.notUploaded
        }
    }

    /// The cached bytes for a document, or nil when absent (or when the
    /// Application Support directory is unresolvable).
    func cachedFile(documentID: String, filename: String) -> URL? {
        guard let location = cacheLocation(documentID: documentID, filename: filename),
              files.fileExists(atPath: location.path)
        else { return nil }
        return location
    }

    /// Returns local bytes for a document: the cache on hit, otherwise a
    /// download from the presigned URL moved into the cache. Relay errors
    /// (`APIError`, e.g. 404 for a not-ready document) propagate unchanged;
    /// session/cache failures surface as `TransferError.transport`.
    func download(document: DocumentRecord) async throws -> URL {
        if let cached = cachedFile(documentID: document.id, filename: document.filename) {
            return cached
        }
        let remote = try await relay.downloadURL(id: document.id)
        let tempURL: URL
        do {
            let (url, response) = try await session.download(from: remote)
            guard let http = response as? HTTPURLResponse, 200 ... 299 ~= http.statusCode else {
                throw TransferError.transport
            }
            tempURL = url
        } catch let transfer as TransferError {
            throw transfer
        } catch {
            throw TransferError.transport
        }
        guard let destination = cacheLocation(documentID: document.id, filename: document.filename) else {
            throw TransferError.transport
        }
        do {
            try files.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if files.fileExists(atPath: destination.path) {
                try files.removeItem(at: destination)
            }
            try files.moveItem(at: tempURL, to: destination)
        } catch {
            throw TransferError.transport
        }
        return destination
    }

    /// Stages picked bytes into the cache under the document's cache name so
    /// a later retry can PUT them without the original picked file (offline
    /// create path: `DocumentFormView` stages on upload failure and
    /// `DocumentsViewModel.retryUpload` reads the staged bytes back).
    func stage(documentID: String, filename: String, fileURL: URL) throws {
        guard let destination = cacheLocation(documentID: documentID, filename: filename) else {
            throw TransferError.transport
        }
        try files.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if files.fileExists(atPath: destination.path) {
            try files.removeItem(at: destination)
        }
        try files.copyItem(at: fileURL, to: destination)
    }

    // MARK: - Cache layout

    private func cacheLocation(documentID: String, filename: String) -> URL? {
        guard let base = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base
            .appendingPathComponent("documents", isDirectory: true)
            .appendingPathComponent("\(documentID)-\(filename)")
    }
}
