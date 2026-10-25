import Combine
import Foundation

/// Timeline view model (§6.2): the event list across one pet or all pets,
/// with adaptive scope chrome. Single-pet households never show the picker,
/// the "All" option, or per-row pet prefixes — the list is that pet's.
/// Multi-pet households get an All + pet picker and per-row pet names.
@MainActor
final class TimelineViewModel: ObservableObject {
    @Published private(set) var events: [EventRecord] = []
    @Published private(set) var pets: [PetRecord] = []
    @Published var selectedPetID: String?
    @Published private(set) var errorMessage: String?

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

    /// Whether the scope picker (and per-row pet prefixes) shows: only for
    /// multi-pet households (`PetScope` owns the rule).
    var showsScopeChrome: Bool {
        PetScope.requiresChrome(petCount: pets.count)
    }

    /// The pet id the list filters by, or nil for all pets. Single-pet
    /// households always filter to that pet (`PetScope` returns nil there —
    /// the whole-household list is that pet's — so the single pet is
    /// resolved explicitly). Otherwise the picker selection wins (nil =
    /// All), clamped to a known pet.
    var effectivePetID: String? {
        if let selected = PetScope.effectiveSelection(
            petCount: pets.count, selectedID: selectedPetID
        ) {
            return pets.contains { $0.id == selected } ? selected : nil
        }
        return pets.count == 1 ? pets.first?.id : nil
    }

    /// Pet names by id for the multi-pet per-row prefix.
    var petNamesByID: [String: String] {
        Dictionary(uniqueKeysWithValues: pets.map { ($0.id, $0.name) })
    }

    /// Reads pets, then the selected pet's events (or every event when the
    /// effective filter is All). Failures surface a generic persistence
    /// message; the previous list stays on screen.
    func load() async {
        do {
            pets = try await store.listPets()
            if let petID = effectivePetID {
                events = try await store.listEvents(petID: petID)
            } else {
                events = try await store.listAllEvents()
            }
            errorMessage = nil
        } catch {
            errorMessage = L10n.errorLocalPersistence.text
        }
    }

    /// Two-step undoable deletion: buffer first (no outbox row yet), then
    /// remove locally, reload, and trigger a sync cycle.
    func delete(_ event: EventRecord) async {
        do {
            try await undo.bufferDeletion(of: [(resource: .event, id: event.id)])
            try await store.removeEventLocal(id: event.id)
            await load()
            if let userID = sessionUserID() {
                sync.trigger(userID: userID)
            }
        } catch {
            errorMessage = L10n.errorLocalPersistence.text
        }
    }
}

/// Row presentation for timeline events (shared by the timeline list and
/// any embedders). Detail summary lines per kind; weight renders through
/// the per-device `UnitLens`.
extension EventRecord {
    /// One-line detail summary: vacc "Vaccine • vet", groom "Service @
    /// place", weight display value, course "Drug — status".
    var timelineSummary: String {
        if let detail = vaccination {
            return "\(detail.vaccine) • \(detail.vet)"
        }
        if let detail = grooming {
            return "\(detail.service) @ \(detail.place)"
        }
        if let detail = weight {
            let display = UnitLens.display(grams: detail.grams, system: UnitLens.current)
            return "\(display.value) \(display.unit)"
        }
        if let course {
            return "\(course.drugName) — \(course.status)"
        }
        return title
    }

    /// SF Symbol name for the event kind.
    var timelineKindIcon: String {
        switch kind {
        case "vaccination": return "syringe"
        case "grooming": return "scissors"
        case "weight": return "scalemass"
        default: return "pills"
        }
    }

    /// Localized kind title for the row badge.
    var timelineKindTitle: String {
        switch kind {
        case "vaccination": return L10n.eventKindVaccination.text
        case "grooming": return L10n.eventKindGrooming.text
        case "weight": return L10n.eventKindWeight.text
        default: return kind
        }
    }

    /// Medium date + short time for the row, falling back to the raw
    /// timestamp when unparseable.
    var timelineDateText: String {
        guard let date = RFC3339Milli.parse(occurredAt) else { return occurredAt }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
