import Foundation

/// Pure validation mirroring the backend rules (so the client rejects before
/// hitting the network, but the server remains the source of truth).
///
/// Passwordless model (Requirements F1/U1): the only inputs are
/// - email: non-empty, valid shape, ≤254, lowercased/trimmed before send.
/// - OTP code: exactly 6 digits.
enum AuthValidator {
    enum Field: String, Hashable, Sendable {
        case email
        case otp
    }

    enum ValidationError: Error, Equatable, Sendable {
        case emailEmpty
        case emailInvalid
        case emailTooLong
        case otpEmpty
        case otpInvalid
    }

    static let maxEmail = 254
    static let otpLength = 6

    static func validateEmail(_ raw: String) -> [ValidationError] {
        var errors: [ValidationError] = []
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if email.isEmpty {
            errors.append(.emailEmpty)
            return errors
        }
        if email.count > maxEmail {
            errors.append(.emailTooLong)
        }
        if !isValidEmail(email) {
            errors.append(.emailInvalid)
        }
        return errors
    }

    /// Validates an OTP code: exactly 6 digits (after trimming whitespace).
    static func validateOtpCode(_ raw: String) -> [ValidationError] {
        var errors: [ValidationError] = []
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.isEmpty {
            errors.append(.otpEmpty)
            return errors
        }
        if code.count != otpLength || !code.allSatisfy({ $0.isNumber }) {
            errors.append(.otpInvalid)
        }
        return errors
    }

    /// Normalizes an email for submission: trimmed + lowercased.
    static func normalize(email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Email shape check mirroring the server's canonical rule (fix #95;
    /// the server remains authoritative). Accepts `local@domain.tld` with
    /// reasonable characters, plus the server's dot-atom restriction on the
    /// local part: no leading, trailing, or consecutive dots.
    static func isValidEmail(_ email: String) -> Bool {
        let pattern = #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        guard email.range(of: pattern, options: .regularExpression) != nil else {
            return false
        }
        guard let at = email.lastIndex(of: "@") else { return false }
        let local = email[..<at]
        if local.hasPrefix(".") || local.hasSuffix(".") || local.contains("..") {
            return false
        }
        return true
    }

    // MARK: - Unified messages (Requirements U4)

    /// A single, merged message for the email field, or `nil` when valid.
    /// Multiple simultaneous email problems are folded into one sentence
    /// rather than listed separately.
    static func unifiedEmailMessage(_ errors: [ValidationError]) -> String? {
        guard !errors.isEmpty else { return nil }
        if errors.contains(.emailEmpty) {
            return L10n.validationEmailEmpty.text
        }
        var fragments: [String] = []
        if errors.contains(.emailInvalid) {
            fragments.append(L10n.validationEmailRuleInvalid.text)
        }
        if errors.contains(.emailTooLong) {
            fragments.append(L10n.validationEmailRuleTooLong.text)
        }
        guard !fragments.isEmpty else { return nil }
        return L10n.validationEmailPrefix.text + " "
            + joinFragments(fragments) + "."
    }

    /// A single, merged message for the OTP field, or `nil` when valid.
    static func unifiedOtpMessage(_ errors: [ValidationError]) -> String? {
        guard !errors.isEmpty else { return nil }
        if errors.contains(.otpEmpty) {
            return L10n.validationOtpEmpty.text
        }
        // .otpInvalid only.
        return L10n.validationOtpPrefix.text + " "
            + L10n.validationOtpRuleInvalid.text + "."
    }

    /// Joins fragments with a localized "and" before the last item:
    /// `["A"]` → "A"; `["A","B"]` → "A and B"; `["A","B","C"]` → "A, B and C".
    static func joinFragments(_ fragments: [String]) -> String {
        guard fragments.count > 1 else { return fragments.first ?? "" }
        let and = L10n.commonAnd.text
        let head = fragments.dropLast().joined(separator: ", ")
        return "\(head) \(and) \(fragments.last!)"
    }
}
