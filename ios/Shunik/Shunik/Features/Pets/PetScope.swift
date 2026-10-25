import Foundation

/// Shared adaptive-shell helper (§6.1): the pet picker chrome appears only in
/// multi-pet households. Single-pet (and zero-pet) contexts render no picker —
/// list view models consult this instead of branching on counts themselves.
enum PetScope {
    /// Whether list chrome (Timeline/Meds/Docs) shows a pet picker.
    static func requiresChrome(petCount: Int) -> Bool {
        petCount > 1
    }

    /// The effective selection: nil for zero/single-pet households (no
    /// picker, no filter), the caller's selection otherwise.
    static func effectiveSelection(petCount: Int, selectedID: String?) -> String? {
        guard petCount > 1 else { return nil }
        return selectedID
    }
}
