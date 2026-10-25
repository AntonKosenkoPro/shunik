import Foundation

// MARK: - Sync cycle (pull-merge → tombstones → drain)

// Implementation of the sync cycle. SyncController.swift keeps the shell:
// lifecycle, triggers, guards, status, and the fence. See tasks.md §5
// for the contract.

@MainActor
extension SyncController {
    // Full cycle: pull-merge (pets → events → intakes → documents),
    // tombstone application, then outbox drain with last-writer-wins
    // conflict recovery. First sync is pull-first: a joining device adopts
    // the relay before pushing anything. Every cycle uses the same order so
    // deletes converge before the outbox pushes (delete-wins) and the drain
    // never resurrects a tombstoned record.
    func runCycle(firstSync: Bool, generation: Int) async {
        guard cycleGeneration == generation else { return }
        cycleRunning = true
        defer { finishCycleTail(generation: generation) }
        guard let userID = checkCycleEntry(generation: generation) else { return }
        guard let relay else {
            if cycleGeneration == generation, boundUserID == userID {
                status = .idle(Date())
            }
            return
        }
        do {
            try await pushBufferedDeletions(relay: relay)
            try await pullAllResources(relay: relay)
            try await applyTombstones(relay: relay)
            let failed = try await drainOutbox(relay: relay)
            if cycleGeneration == generation, boundUserID == userID {
                status = failed == 0 ? .idle(Date()) : .error("Some changes couldn't sync — will retry")
            }
        } catch {
            Self.logger.error("sync cycle failed")
            if cycleGeneration == generation, boundUserID == userID {
                status = .error("Sync failed — will retry")
            }
        }
        _ = firstSync
    }

    /// Entry guards shared by every cycle start: bound account present,
    /// session still matches it, deletion fence clear. Returns the bound
    /// user id when the cycle may proceed; parks as `.inactive` on the
    /// way out otherwise.
    private func checkCycleEntry(generation: Int) -> String? {
        guard let userID = boundUserID else {
            Self.logger.error("sync cycle skipped: no bound account")
            status = .inactive
            return nil
        }
        guard sessionUserIDProvider() == userID else {
            Self.logger.error("sync cycle aborted: account changed mid-cycle")
            if cycleGeneration == generation, boundUserID == userID {
                status = .inactive
            }
            return nil
        }
        if refuseWhenFenced(userID: userID, generation: generation) { return nil }
        return userID
    }

    // MARK: - Push buffered deletions (push-then-commit)

    /// Pushes every buffered (undoable) deletion to the relay, then commits
    /// the buffer (which enqueues the outbox DELETE rows the drain picks
    /// up). While set, undo of those rows is refused (in-flight guard).
    private func pushBufferedDeletions(relay: any SyncRelay) async throws {
        let buffered = try await store.bufferedDeletions()
        guard !buffered.isEmpty else { return }
        await store.setUndoPushInFlight(true)
        defer { Task { [self] in await self.store.setUndoPushInFlight(false) } }
        for deletion in buffered {
            switch deletion.resource {
            case SyncResource.pet.rawValue:
                try await relay.deletePet(id: deletion.recordID)
            case SyncResource.event.rawValue:
                try await relay.deleteEvent(id: deletion.recordID)
            case SyncResource.intake.rawValue:
                try await relay.deleteIntake(id: deletion.recordID)
            case SyncResource.document.rawValue:
                try await relay.deleteDocument(id: deletion.recordID)
            default:
                Self.logger.error("sync: unknown buffered resource \(deletion.resource, privacy: .public)")
            }
        }
        try await store.undoBufferCommitAll()
    }

    // MARK: - Pull-merge

    private func pullAllResources(relay: any SyncRelay) async throws {
        try await pullPets(relay: relay)
        try await pullEvents(relay: relay)
        try await pullIntakes(relay: relay)
        try await pullDocuments(relay: relay)
    }

    /// Advances a per-resource cursor to the newest pulled row. Equal
    /// timestamps do not advance (the next pull re-fetches the boundary row
    /// and upserts it idempotently) — matches the relay's inclusive bounds.
    private func advanceCursor(resource: String, since last: Date?, dates: [Date]) async throws -> Date? {
        let newest = dates.max()
        guard let newest else { return last }
        if let last, newest <= last { return last }
        try await store.setLastSyncedAt(resource: resource, date: newest)
        return newest
    }

    private func pullPets(relay: any SyncRelay) async throws {
        let since = try await store.lastSyncedAt(resource: SyncCursorKey.pets)
        let page = try await relay.listPets(since: sinceString(since))
        for var pet in page.pets {
            pet.updatedAt = RFC3339Milli.normalize(pet.updatedAt)
            pet.createdAt = RFC3339Milli.normalize(pet.createdAt)
            try await store.upsertPet(pet)
        }
        _ = try await advanceCursor(
            resource: SyncCursorKey.pets,
            since: since,
            dates: page.pets.compactMap { RFC3339Milli.parse($0.updatedAt) }
        )
    }

    private func pullEvents(relay: any SyncRelay) async throws {
        let since = try await store.lastSyncedAt(resource: SyncCursorKey.events)
        let page = try await relay.listEvents(since: sinceString(since), petID: nil)
        for var event in page.events {
            event.updatedAt = RFC3339Milli.normalize(event.updatedAt)
            event.createdAt = RFC3339Milli.normalize(event.createdAt)
            event.occurredAt = RFC3339Milli.normalize(event.occurredAt)
            if let nextDue = event.nextDueAt {
                event.nextDueAt = RFC3339Milli.normalize(nextDue)
            }
            try await store.upsertEvent(event)
        }
        _ = try await advanceCursor(
            resource: SyncCursorKey.events,
            since: since,
            dates: page.events.compactMap { RFC3339Milli.parse($0.updatedAt) }
        )
    }

    private func pullIntakes(relay: any SyncRelay) async throws {
        let since = try await store.lastSyncedAt(resource: SyncCursorKey.intakes)
        let page = try await relay.listIntakes(since: sinceString(since), courseID: nil)
        for var intake in page.intakes {
            intake.updatedAt = RFC3339Milli.normalize(intake.updatedAt)
            intake.createdAt = RFC3339Milli.normalize(intake.createdAt)
            intake.dueAt = intake.dueAt.map(RFC3339Milli.normalize)
            intake.takenAt = intake.takenAt.map(RFC3339Milli.normalize)
            try await store.upsertIntake(intake)
        }
        _ = try await advanceCursor(
            resource: SyncCursorKey.intakes,
            since: since,
            dates: page.intakes.compactMap { RFC3339Milli.parse($0.updatedAt) }
        )
    }

    private func pullDocuments(relay: any SyncRelay) async throws {
        let since = try await store.lastSyncedAt(resource: SyncCursorKey.documents)
        let page = try await relay.listDocuments(since: sinceString(since))
        for var document in page.documents {
            document.updatedAt = RFC3339Milli.normalize(document.updatedAt)
            document.createdAt = RFC3339Milli.normalize(document.createdAt)
            try await store.upsertDocument(document)
        }
        _ = try await advanceCursor(
            resource: SyncCursorKey.documents,
            since: since,
            dates: page.documents.compactMap { RFC3339Milli.parse($0.updatedAt) }
        )
    }

    /// Formats a cursor for `?modified_since=` / `?deleted_since=`. Nil
    /// stays nil (the relay lists from scratch); dates serialize full
    /// precision so no server write falls strictly between two pulls.
    private func sinceString(_ date: Date?) -> String? {
        guard let date else { return nil }
        return RFC3339Milli.format(date)
    }

    // MARK: - Tombstones (delete-wins)

    /// Applies the household's deletions. Records deleted locally are
    /// skipped (convergence is already in flight); a clean local row newer
    /// than the tombstone is a recreation that won — it is kept (the next
    /// local edit re-enqueues a push; no resurrection path is needed since
    /// the row never left); everything else is removed without an outbox row.
    private func applyTombstones(relay: any SyncRelay) async throws {
        let since = try await store.lastSyncedAt(resource: SyncCursorKey.deletions)
        let page = try await relay.listDeletions(since: sinceString(since))
        var fresh: [TombstoneRecord] = []
        for tomb in page.deletions {
            if try await store.isLocallyDeleted(resource: tomb.resource, recordID: tomb.recordID) {
                continue
            }
            if let localUpdated = try await localUpdatedAt(resource: tomb.resource, recordID: tomb.recordID),
               let tombDate = RFC3339Milli.parse(tomb.deletedAt),
               localUpdated > tombDate {
                Self.logger.info("sync: kept recreation winning over tombstone \(tomb.resource, privacy: .public)/\(tomb.recordID, privacy: .public)")
                continue
            }
            fresh.append(tomb)
        }
        if !fresh.isEmpty {
            try await store.applyDeletions(fresh)
        }
        _ = try await advanceCursor(
            resource: SyncCursorKey.deletions,
            since: since,
            dates: page.deletions.compactMap { RFC3339Milli.parse($0.deletedAt) }
        )
    }

    /// The local row's updated_at for recreation-wins checks, or nil when
    /// the row does not exist locally.
    private func localUpdatedAt(resource: String, recordID: String) async throws -> Date? {
        let iso: String?
        switch resource {
        case SyncResource.pet.rawValue:
            iso = try await store.getPet(id: recordID)?.updatedAt
        case SyncResource.event.rawValue:
            iso = try await store.getEvent(id: recordID)?.updatedAt
        case SyncResource.intake.rawValue:
            iso = try await store.getIntake(id: recordID)?.updatedAt
        case SyncResource.document.rawValue:
            iso = try await store.getDocument(id: recordID)?.updatedAt
        default:
            return nil
        }
        guard let iso else { return nil }
        return RFC3339Milli.parse(iso)
    }
}
