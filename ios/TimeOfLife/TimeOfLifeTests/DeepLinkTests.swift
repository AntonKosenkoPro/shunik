import Testing
import Foundation
@testable import TimeOfLife

@Suite("DeepLink")
struct DeepLinkTests {

    @Test("lifio://track parses to track")
    func trackParses() {
        #expect(DeepLink.parse(URL(string: "lifio://track")!) == .track)
    }

    @Test("unknown links are ignored")
    func unknownIgnored() {
        #expect(DeepLink.parse(URL(string: "lifio://history")!) == nil)
        #expect(DeepLink.parse(URL(string: "https://example.com/track")!) == nil)
        #expect(DeepLink.parse(URL(string: "lifio://")!) == nil)
    }

    @Test("the shared stop URL parses to stopTimer")
    func stopURLParses() {
        #expect(DeepLink.parse(URL(string: "lifio://track?stop=1")!) == .stopTimer)
    }

    @Test("track with other query items stays track")
    func trackQueryStaysTrack() {
        #expect(DeepLink.parse(URL(string: "lifio://track?foo=bar")!) == .track)
        #expect(DeepLink.parse(URL(string: "lifio://track?stop=0")!) == .track)
    }
}
