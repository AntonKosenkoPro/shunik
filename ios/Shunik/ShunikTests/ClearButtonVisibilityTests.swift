import Testing
import Foundation
@testable import Shunik

/// Visibility rule for every clear (`×`) button (issue #42 follow-ups):
/// shown only when the field is focused AND holds non-empty text, never
/// when locked/read-only. Pinned against the pure
/// `ClearButtonVisibility.shouldShow(isFocused:text:isLocked:)` helper so
/// the rule is unit-testable (SwiftUI view conditions are not).
@Suite("ClearButtonVisibility")
struct ClearButtonVisibilityTests {

    @Test("focused field with text shows the button")
    func focusedWithTextShows() {
        #expect(ClearButtonVisibility.shouldShow(isFocused: true, text: "Gym") == true)
    }

    @Test("unfocused field with text hides the button")
    func unfocusedWithTextHides() {
        #expect(ClearButtonVisibility.shouldShow(isFocused: false, text: "Gym") == false)
    }

    @Test("focused empty field hides the button")
    func focusedEmptyHides() {
        #expect(ClearButtonVisibility.shouldShow(isFocused: true, text: "") == false)
    }

    @Test("unfocused empty field hides the button")
    func unfocusedEmptyHides() {
        #expect(ClearButtonVisibility.shouldShow(isFocused: false, text: "") == false)
    }

    @Test("locked form hides the button even when focused with text")
    func lockedHides() {
        #expect(ClearButtonVisibility.shouldShow(isFocused: true, text: "Gym", isLocked: true) == false)
    }

    @Test("whitespace-only text counts as non-empty")
    func whitespaceCountsAsText() {
        // Corner: "  " shows the button; one tap clears to truly empty,
        // which re-hides it (the validity gate already trims).
        #expect(ClearButtonVisibility.shouldShow(isFocused: true, text: "  ") == true)
    }

    @Test("multiline text counts as non-empty")
    func multilineCountsAsText() {
        // The notes editor holds newlines: any non-empty string shows the
        // button, including text that is only newlines.
        #expect(ClearButtonVisibility.shouldShow(isFocused: true, text: "warmup\n5x5") == true)
        #expect(ClearButtonVisibility.shouldShow(isFocused: true, text: "\n") == true)
    }
}
