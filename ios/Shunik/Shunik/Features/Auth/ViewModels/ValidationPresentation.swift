import Foundation

/// Per-field error presentation surfaced to views.
///
/// Each field carries **at most one** merged message (Requirements U4: several
/// similar errors collapse into a single unified message). A `nil` value means
/// the field has no error.
struct FieldErrors: Equatable {
    var email: String?
    var otp: String?

    static let empty = FieldErrors(email: nil, otp: nil)
    var isEmpty: Bool { email == nil && otp == nil }
}
