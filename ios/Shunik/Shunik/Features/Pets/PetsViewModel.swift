import Foundation
import Combine

/// Pet list view model (§6.1): reads the household's pets from `LocalStore`
/// and deletes via the two-step undo contract — buffer the deletion snapshot
/// FIRST, then remove the row locally. No outbox row is created here: the
/// buffered deletion pushes on the next sync cycle (or commits on cold
/// launch), so an undo never touches the relay.
@MainActor
final class PetsViewModel: ObservableObject {
    @Published var pets: [PetRecord] = []
    @Published var errorMessage: String?

    private let store: LocalStore
    private let undo: UndoBufferStore
    private let sync: SyncController
    private let sessionUserID: () -> String?

    init(
        store: LocalStore,
        undo: UndoBufferStore,
        sync: SyncController,
        sessionUserID: @escaping () -> String?
    ) {
        self.store = store
        self.undo = undo
        self.sync = sync
        self.sessionUserID = sessionUserID
    }

    /// Reloads the household's pets (already name-sorted by the store).
    func load() async {
        do {
            pets = try await store.listPets()
            errorMessage = nil
        } catch {
            errorMessage = L10n.errorLocalPersistence.text
        }
    }

    /// Undoable delete: buffer the snapshot first (crash between the steps
    /// leaves the row present AND restorable), then remove the row locally,
    /// reload, and nudge sync so the buffered deletion pushes.
    func delete(_ pet: PetRecord) async {
        do {
            try await undo.bufferDeletion(of: [(resource: .pet, id: pet.id)])
            try await store.removePetLocal(id: pet.id)
            await load()
            if let userID = sessionUserID() {
                sync.trigger(userID: userID)
            }
        } catch {
            errorMessage = L10n.errorLocalPersistence.text
        }
    }
}
