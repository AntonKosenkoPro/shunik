import Testing
import Foundation
@testable import Shunik

@Suite("DeepLink")
struct DeepLinkTests {

    @Test("shunik://track parses to track")
    func trackParses() {
        #expect(DeepLink.parse(URL(string: "shunik://track")!) == .track)
    }

    @Test("unknown links are ignored")
    func unknownIgnored() {
        #expect(DeepLink.parse(URL(string: "shunik://history")!) == nil)
        #expect(DeepLink.parse(URL(string: "https://example.com/track")!) == nil)
        #expect(DeepLink.parse(URL(string: "shunik://")!) == nil)
    }

    @Test("the shared stop URL parses to stopTimer")
    func stopURLParses() {
        #expect(DeepLink.parse(URL(string: "shunik://track?stop=1")!) == .stopTimer)
    }

    @Test("track with other query items stays track")
    func trackQueryStaysTrack() {
        #expect(DeepLink.parse(URL(string: "shunik://track?foo=bar")!) == .track)
        #expect(DeepLink.parse(URL(string: "shunik://track?stop=0")!) == .track)
    }
}
