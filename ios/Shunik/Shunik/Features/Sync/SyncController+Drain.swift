import Foundation

 // MARK: - Sync outbox drain

 // (Implementation; SyncController.swift keeps the shell: lifecycle, triggers,
 // guards, status, and the fence. See tasks.md §5 for the contract.)

/// Sync drain failures: loud, per-row, never silent. Rows that fail this
/// way stay queued and the cycle reports `.error` so the next trigger
/// retries them.
enum SyncDrainError: Error, Equatable {
    /// An outbox row names a resource the drain does not know.
    case unknownRow
    /// An outbox row carries no payload where one is required.
    case missingPayload
    /// An outbox payload does not decode as its resource body.
    case undecodablePayload
}

@MainActor
extension SyncController {
    func drainOutbox(relay: any SyncRelay) async throws -> Int {
        let rows = try await store.outboxRows()
        let order: [String] = [
            SyncResource.pet.rawValue,
            SyncResource.event.rawValue,
            SyncResource.intake.rawValue,
            SyncResource.document.rawValue,
        ]
        var failed = 0
        for resource in order {
            for row in rows where row.resource == resource {
                do {
                    try await drainRow(row, relay: relay)
                } catch {
                    failed += 1
                    Self.logger.error("sync: row failed loudly, kept for retry: \(row.resource, privacy: .public)/\(row.recordID, privacy: .public)")
                }
            }
        }
        return failed
    }

    private func drainRow(_ row: OutboxRow, relay: any SyncRelay) async throws {
        switch row.resource {
        case SyncResource.pet.rawValue:
            try await drainPetRow(row, relay: relay)
        case SyncResource.event.rawValue:
            try await drainEventRow(row, relay: relay)
        case SyncResource.intake.rawValue:
            try await drainIntakeRow(row, relay: relay)
        case SyncResource.document.rawValue:
            try await drainDocumentRow(row, relay: relay)
        default:
            Self.logger.error("sync: unknown outbox resource, kept: \(row.resource, privacy: .public)")
            throw SyncDrainError.unknownRow
        }
    }

    private func drainPetRow(_ row: OutboxRow, relay: any SyncRelay) async throws {
        switch row.op {
        case "create":
            let record: PetRecord = try decodePayload(row)
            _ = try await relay.createPet(record)
            try await store.removeOutboxRow(id: row.id)
        case "update":
            let body: PetUpdateBody = try decodePayload(row)
            do {
                _ = try await relay.updatePet(id: row.recordID, body: body)
                try await store.removeOutboxRow(id: row.id)
            } catch let conflict as ConflictError<PetRecord> {
                try await rebasePet(row: row, body: body, server: conflict.server, relay: relay)
            } catch let api as APIError where api.code == "not_found" {
                try await resurrectPet(row: row, relay: relay)
            }
        case "delete":
            try await pushDelete(row: row, relay: relay)
            try await store.removeOutboxRow(id: row.id)
        default:
            Self.logger.error("sync: unknown pet op, kept: \(row.op, privacy: .public)")
            throw SyncDrainError.unknownRow
        }
    }

    private func drainEventRow(_ row: OutboxRow, relay: any SyncRelay) async throws {
        switch row.op {
        case "create":
            let record: EventRecord = try decodePayload(row)
            _ = try await relay.createEvent(record)
            try await store.removeOutboxRow(id: row.id)
        case "update":
            let body: EventUpdateBody = try decodePayload(row)
            do {
                _ = try await relay.updateEvent(id: row.recordID, body: body)
                try await store.removeOutboxRow(id: row.id)
            } catch let conflict as ConflictError<EventRecord> {
                try await rebaseEvent(row: row, body: body, server: conflict.server, relay: relay)
            } catch let api as APIError where api.code == "not_found" {
                try await resurrectEvent(row: row, relay: relay)
            }
        case "delete":
            try await pushDelete(row: row, relay: relay)
            try await store.removeOutboxRow(id: row.id)
        default:
            Self.logger.error("sync: unknown event op, kept: \(row.op, privacy: .public)")
            throw SyncDrainError.unknownRow
        }
    }

    private func drainIntakeRow(_ row: OutboxRow, relay: any SyncRelay) async throws {
        switch row.op {
        case "create":
            let record: IntakeRecord = try decodePayload(row)
            _ = try await relay.createIntake(record)
            try await store.removeOutboxRow(id: row.id)
        case "update":
            let body: IntakeUpdateBody = try decodePayload(row)
            do {
                _ = try await relay.updateIntake(id: row.recordID, body: body)
                try await store.removeOutboxRow(id: row.id)
            } catch let conflict as ConflictError<IntakeRecord> {
                try await rebaseIntake(row: row, body: body, server: conflict.server, relay: relay)
            } catch let api as APIError where api.code == "not_found" {
                try await resurrectIntake(row: row, relay: relay)
            }
        case "delete":
            try await pushDelete(row: row, relay: relay)
            try await store.removeOutboxRow(id: row.id)
        default:
            Self.logger.error("sync: unknown intake op, kept: \(row.op, privacy: .public)")
            throw SyncDrainError.unknownRow
        }
    }

    private func drainDocumentRow(_ row: OutboxRow, relay: any SyncRelay) async throws {
        switch row.op {
        case "create":
            let record: DocumentRecord = try decodePayload(row)
            _ = try await relay.createDocument(record)
            try await store.removeOutboxRow(id: row.id)
        case "update":
            let body: DocumentUpdateBody = try decodePayload(row)
            do {
                _ = try await relay.updateDocument(id: row.recordID, body: body)
                try await store.removeOutboxRow(id: row.id)
            } catch let conflict as ConflictError<DocumentRecord> {
                try await rebaseDocument(row: row, body: body, server: conflict.server, relay: relay)
            } catch let api as APIError where api.code == "not_found" {
                try await resurrectDocument(row: row, relay: relay)
            }
        case "delete":
            try await pushDelete(row: row, relay: relay)
            try await store.removeOutboxRow(id: row.id)
        default:
            Self.logger.error("sync: unknown document op, kept: \(row.op, privacy: .public)")
            throw SyncDrainError.unknownRow
        }
    }

    /// Rebase-once: point the queued update at the server's current version
    /// and retry a single time. A second conflict means someone else is
    /// writing concurrently — adopt the server copy and drop the row
    /// (last-writer-wins, keep-latest).
    private func rebasePet(row: OutboxRow, body: PetUpdateBody, server: PetRecord, relay: any SyncRelay) async throws {
        var rebased = body
        rebased.baseUpdatedAt = server.updatedAt
        do {
            _ = try await relay.updatePet(id: row.recordID, body: rebased)
            try await store.removeOutboxRow(id: row.id)
        } catch {
            try await store.upsertPet(server)
            try await store.removeOutboxRow(id: row.id)
        }
    }

    private func rebaseEvent(row: OutboxRow, body: EventUpdateBody, server: EventRecord, relay: any SyncRelay) async throws {
        var rebased = body
        rebased.baseUpdatedAt = server.updatedAt
        do {
            _ = try await relay.updateEvent(id: row.recordID, body: rebased)
            try await store.removeOutboxRow(id: row.id)
        } catch {
            try await store.upsertEvent(server)
            try await store.removeOutboxRow(id: row.id)
        }
    }

    private func rebaseIntake(row: OutboxRow, body: IntakeUpdateBody, server: IntakeRecord, relay: any SyncRelay) async throws {
        var rebased = body
        rebased.baseUpdatedAt = server.updatedAt
        do {
            _ = try await relay.updateIntake(id: row.recordID, body: rebased)
            try await store.removeOutboxRow(id: row.id)
        } catch {
            try await store.upsertIntake(server)
            try await store.removeOutboxRow(id: row.id)
        }
    }

    private func rebaseDocument(row: OutboxRow, body: DocumentUpdateBody, server: DocumentRecord, relay: any SyncRelay) async throws {
        var rebased = body
        rebased.baseUpdatedAt = server.updatedAt
        do {
            _ = try await relay.updateDocument(id: row.recordID, body: rebased)
            try await store.removeOutboxRow(id: row.id)
        } catch {
            try await store.upsertDocument(server)
            try await store.removeOutboxRow(id: row.id)
        }
    }

    /// Resurrect-once: the relay has no row for an update (deleted elsewhere
    /// or create never pushed). Re-create from the current local row, then
    /// drop the update — the create carries the latest local shape.
    private func resurrectPet(row: OutboxRow, relay: any SyncRelay) async throws {
        guard let local = try await store.getPet(id: row.recordID) else {
            Self.logger.error("sync: update target gone locally, dropping row \(row.recordID, privacy: .public)")
            try await store.removeOutboxRow(id: row.id)
            return
        }
        _ = try await relay.createPet(local)
        try await store.removeOutboxRow(id: row.id)
    }

    private func resurrectEvent(row: OutboxRow, relay: any SyncRelay) async throws {
        guard let local = try await store.getEvent(id: row.recordID) else {
            Self.logger.error("sync: update target gone locally, dropping row \(row.recordID, privacy: .public)")
            try await store.removeOutboxRow(id: row.id)
            return
        }
        _ = try await relay.createEvent(local)
        try await store.removeOutboxRow(id: row.id)
    }

    private func resurrectIntake(row: OutboxRow, relay: any SyncRelay) async throws {
        guard let local = try await store.getIntake(id: row.recordID) else {
            Self.logger.error("sync: update target gone locally, dropping row \(row.recordID, privacy: .public)")
            try await store.removeOutboxRow(id: row.id)
            return
        }
        _ = try await relay.createIntake(local)
        try await store.removeOutboxRow(id: row.id)
    }

    private func resurrectDocument(row: OutboxRow, relay: any SyncRelay) async throws {
        guard let local = try await store.getDocument(id: row.recordID) else {
            Self.logger.error("sync: update target gone locally, dropping row \(row.recordID, privacy: .public)")
            try await store.removeOutboxRow(id: row.id)
            return
        }
        _ = try await relay.createDocument(local)
        try await store.removeOutboxRow(id: row.id)
    }

    private func pushDelete(row: OutboxRow, relay: any SyncRelay) async throws {
        switch row.resource {
        case SyncResource.pet.rawValue:
            try await relay.deletePet(id: row.recordID)
        case SyncResource.event.rawValue:
            try await relay.deleteEvent(id: row.recordID)
        case SyncResource.intake.rawValue:
            try await relay.deleteIntake(id: row.recordID)
        case SyncResource.document.rawValue:
            try await relay.deleteDocument(id: row.recordID)
        default:
            Self.logger.error("sync: unknown delete resource \(row.resource, privacy: .public)")
            throw SyncDrainError.unknownRow
        }
    }

    /// Decodes an outbox JSON payload. A missing or undecodable payload is
    /// a loud failure (kept row, error status) — never a silent skip.
    private func decodePayload<T: Decodable>(_ row: OutboxRow) throws -> T {
        guard let json = row.payload, let data = json.data(using: .utf8) else {
            throw SyncDrainError.missingPayload
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SyncDrainError.undecodablePayload
        }
    }
}
