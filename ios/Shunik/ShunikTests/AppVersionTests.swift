import Testing
import Foundation
@testable import Shunik

@Suite("AppVersion")
struct AppVersionTests {

    @Test("Release formats marketing and commit SHA with v prefix and no suffix")
    func releaseFormat() {
        let text = AppVersion.formatted(marketing: "0.1.0", build: "a1b2c3d", isDebug: false, debugSuffix: "Debug")
        #expect(text == "v0.1.0 (a1b2c3d)")
    }

    @Test("Debug appends the localized suffix after a bullet")
    func debugFormat() {
        let text = AppVersion.formatted(marketing: "0.1.0", build: "a1b2c3d", isDebug: true, debugSuffix: "Debug")
        #expect(text == "v0.1.0 (a1b2c3d) • Debug")
    }

    @Test("missing bundle keys fall back to placeholders")
    func missingKeys() {
        let text = AppVersion.formatted(marketing: nil, build: nil, isDebug: false, debugSuffix: "Debug")
        #expect(text == "v? (?)")
    }

    @Test("runtime text reflects the stamped commit SHA or the placeholder")
    func runtimeSHA() {
        let stamped = Bundle.main.object(forInfoDictionaryKey: "GIT_COMMIT_SHA") as? String
        if let stamped {
            #expect(AppVersion.text.contains("(\(stamped))"))
        } else {
            #expect(AppVersion.text.contains("(?)"))
        }
    }

    @Test("runtime text matches the running configuration")
    func runtimeText() {
        #if DEBUG
        #expect(AppVersion.text.hasSuffix("• \(L10n.profileVersionDebugSuffix.text)"))
        #else
        #expect(!AppVersion.text.contains("•"))
        #endif
    }
}
