import Testing
import Foundation
@testable import Shunik

@Suite("AuthValidator")
struct AuthValidatorTests {

    // MARK: - Email validation

    @Test("valid email passes validation")
    func validEmail() {
        #expect(AuthValidator.validateEmail("user@example.com").isEmpty)
        #expect(AuthValidator.validateEmail("User.Name+1@sub.example.co").isEmpty)
        #expect(AuthValidator.validateEmail("test@domain.io").isEmpty)
    }

    @Test("empty email fails validation")
    func emptyEmail() {
        #expect(AuthValidator.validateEmail("") == [.emailEmpty])
        #expect(AuthValidator.validateEmail("   ") == [.emailEmpty])
        #expect(AuthValidator.validateEmail("\n\t") == [.emailEmpty])
    }

    @Test("email without @ fails validation")
    func emailWithoutAt() {
        let errors = AuthValidator.validateEmail("notanemail")
        #expect(errors.contains(.emailInvalid))
    }

    @Test("email over 254 chars fails validation")
    func emailTooLong() {
        let local = String(repeating: "a", count: 250)
        let email = "\(local)@b.co"
        #expect(email.count > 254)
        let errors = AuthValidator.validateEmail(email)
        #expect(errors.contains(.emailTooLong))
    }

    @Test("email with invalid domain fails")
    func invalidDomain() {
        #expect(AuthValidator.validateEmail("a@").contains(.emailInvalid))
        #expect(AuthValidator.validateEmail("a@b").contains(.emailInvalid))
        #expect(AuthValidator.validateEmail("a@b.c").contains(.emailInvalid))
    }

    @Test("dot-edge local parts are rejected (mirrors server #95 vectors)")
    func dotEdgeLocalParts() {
        // Kept in sync with TestRequestOTP_RejectsDotEdgeLocalParts (backend);
        // the server is authoritative, this is instant inline feedback only.
        for email in [".a@example.com", "a..b@example.com", "a.@example.com"] {
            #expect(AuthValidator.validateEmail(email).contains(.emailInvalid), "expected \(email) to be invalid")
        }
    }

    @Test("representative valid senders are accepted (mirrors server #95 vectors)")
    func representativeValidSenders() {
        for email in ["user@example.com", "user+tag@example.com", "first.last@example.com"] {
            #expect(AuthValidator.validateEmail(email).isEmpty, "expected \(email) to be valid")
        }
    }

    @Test("normalize trims whitespace and lowercases")
    func normalize() {
        #expect(AuthValidator.normalize(email: "  Foo@Bar.COM ") == "foo@bar.com")
        #expect(AuthValidator.normalize(email: "USER@Example.com") == "user@example.com")
    }

    // MARK: - OTP validation

    @Test("valid 6-digit OTP passes validation")
    func validOTP() {
        #expect(AuthValidator.validateOtpCode("123456").isEmpty)
        #expect(AuthValidator.validateOtpCode("000000").isEmpty)
        #expect(AuthValidator.validateOtpCode("999999").isEmpty)
    }

    @Test("empty OTP fails validation")
    func emptyOTP() {
        #expect(AuthValidator.validateOtpCode("") == [.otpEmpty])
        #expect(AuthValidator.validateOtpCode("   ") == [.otpEmpty])
    }

    @Test("OTP with letters fails validation")
    func otpWithLetters() {
        #expect(AuthValidator.validateOtpCode("abcdef").contains(.otpInvalid))
        #expect(AuthValidator.validateOtpCode("12a456").contains(.otpInvalid))
        #expect(AuthValidator.validateOtpCode("abc123").contains(.otpInvalid))
    }

    @Test("OTP with 5 digits fails validation")
    func otpTooShort() {
        #expect(AuthValidator.validateOtpCode("12345").contains(.otpInvalid))
    }

    @Test("OTP with 7 digits fails validation")
    func otpTooLong() {
        #expect(AuthValidator.validateOtpCode("1234567").contains(.otpInvalid))
    }

    // MARK: - Unified messages

    @Test("no error message when valid")
    func unifiedNone() {
        #expect(AuthValidator.unifiedEmailMessage([]) == nil)
        #expect(AuthValidator.unifiedOtpMessage([]) == nil)
    }

    @Test("unified error message for empty email")
    func unifiedEmptyEmail() {
        let msg = AuthValidator.unifiedEmailMessage([.emailEmpty])
        #expect(msg != nil)
        #expect(msg == NSLocalizedString("validation.emailEmpty", comment: ""))
    }

    @Test("unified error message for empty OTP")
    func unifiedEmptyOTP() {
        let msg = AuthValidator.unifiedOtpMessage([.otpEmpty])
        #expect(msg != nil)
        #expect(msg == NSLocalizedString("validation.otpEmpty", comment: ""))
    }

    @Test("unified error message combines invalid and too long for email")
    func unifiedEmailMultipleRules() throws {
        let local = String(repeating: "a", count: 251)
        let errors = AuthValidator.validateEmail("\(local)@b.c")
        #expect(errors.contains(.emailTooLong))
        #expect(errors.contains(.emailInvalid))

        let msg = AuthValidator.unifiedEmailMessage(errors)
        let message = try #require(msg)
        #expect(message.contains(NSLocalizedString("validation.email.rule.invalid", comment: "")))
        #expect(message.contains(NSLocalizedString("validation.email.rule.tooLong", comment: "")))
    }

    @Test("unified OTP message for invalid code")
    func unifiedInvalidOTP() {
        let expected = NSLocalizedString("validation.otp.prefix", comment: "") + " "
            + NSLocalizedString("validation.otp.rule.invalid", comment: "") + "."
        #expect(AuthValidator.unifiedOtpMessage([.otpInvalid]) == expected)
    }

    @Test("joinFragments grammar handles single, double, and triple items")
    func joinFragments() {
        let and = NSLocalizedString("common.and", comment: "")
        #expect(AuthValidator.joinFragments(["A"]) == "A")
        #expect(AuthValidator.joinFragments(["A", "B"]) == "A \(and) B")
        #expect(AuthValidator.joinFragments(["A", "B", "C"]) == "A, B \(and) C")
    }
}
