import Foundation
import Combine

/// Pet detail view model (§6.1): one pet plus its related rows — recent
/// events (newest first, per the store), medication courses (kind
/// `med_course`), linked documents, and the latest weight (newest kind
/// `weight` event). No pet prefix/filtering here: this is a single-pet
/// context (the adaptive rule lives in `PetScope` for list models).
@MainActor
final class PetDetailViewModel: ObservableObject {
    @Published var pet: PetRecord?
    @Published var events: [EventRecord] = []
    @Published var courses: [EventRecord] = []
    @Published var documents: [DocumentRecord] = []
    @Published var latestWeight: EventRecord?
    @Published var errorMessage: String?

    private let store: LocalStore

    init(store: LocalStore) {
        self.store = store
    }

    func load(petID: String) async {
        do {
            pet = try await store.getPet(id: petID)
            let all = try await store.listEvents(petID: petID)
            events = all
            courses = all.filter { $0.kind == "med_course" }
            latestWeight = all.first { $0.kind == "weight" }
            documents = try await store.listDocuments().filter { $0.petIDs.contains(petID) }
            errorMessage = nil
        } catch {
            errorMessage = L10n.errorLocalPersistence.text
        }
    }
}
