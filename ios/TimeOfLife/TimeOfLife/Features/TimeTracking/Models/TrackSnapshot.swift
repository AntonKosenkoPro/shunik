import Foundation

/// Everything Track's first paint needs, resolved in one query batch
/// (steady-track-launch): the launch gate preloads it before mounting so
/// the first visible paint is complete, and `TrackViewModel.load()`
/// consumes the same snapshot — one source of truth, two call sites.
///
/// `restoredName` carries the name field's restored text: the running
/// draft's text when a run is active, nil otherwise — a plain load never
/// clobbers typed input.
struct TrackSnapshot: Equatable, Sendable {
    var recents: [ExactName]
    var allNames: [ExactName]
    var categories: [String: Category]
    var draft: RunningTimerDraft?
    var restoredName: String?
}
