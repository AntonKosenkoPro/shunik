import Testing
import Foundation
@testable import Shunik

@Suite("TimeFormatter")
struct TimeFormatterTests {

    @Test("formats zero seconds as 00:00")
    func zeroSeconds() {
        #expect(TimeFormatter.formattedDuration(0) == "00:00")
    }

    @Test("formats seconds only")
    func secondsOnly() {
        #expect(TimeFormatter.formattedDuration(45) == "00:45")
    }

    @Test("formats minutes and seconds")
    func minutesAndSeconds() {
        #expect(TimeFormatter.formattedDuration(125) == "02:05")
    }

    @Test("formats hours, minutes and seconds")
    func hoursMinutesAndSeconds() {
        #expect(TimeFormatter.formattedDuration(3723) == "1:02:03")
    }

    @Test("rounds fractional seconds")
    func roundsFractionalSeconds() {
        #expect(TimeFormatter.formattedDuration(59.6) == "01:00")
    }

    @Test("clamps negative intervals to zero")
    func clampsNegative() {
        #expect(TimeFormatter.formattedDuration(-10) == "00:00")
    }
}
