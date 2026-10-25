import Testing
import Foundation
@testable import Shunik

@Suite("AppConfig")
struct AppConfigTests {

    @Test("parseBaseURL returns default for nil input")
    func nilInput() {
        let url = AppConfig.parseBaseURL(nil)
        #expect(url.absoluteString == "http://127.0.0.1:8080")
    }

    @Test("parseBaseURL returns default for empty input")
    func emptyInput() {
        let url = AppConfig.parseBaseURL("   ")
        #expect(url.absoluteString == "http://127.0.0.1:8080")
    }

    @Test("parseBaseURL strips surrounding quotes")
    func quotedInput() {
        let url = AppConfig.parseBaseURL("\"http://192.168.1.42:8080\"")
        #expect(url.absoluteString == "http://192.168.1.42:8080")
    }

    @Test("parseBaseURL strips trailing slash")
    func trailingSlash() {
        let url = AppConfig.parseBaseURL("http://192.168.1.42:8080/")
        #expect(url.absoluteString == "http://192.168.1.42:8080")
    }

    @Test("parseBaseURL falls back to default for scheme-only value")
    func schemeOnly() {
        let url = AppConfig.parseBaseURL("http:")
        #expect(url.absoluteString == "http://127.0.0.1:8080")
    }

    @Test("parseBaseURL falls back to default for invalid value")
    func invalidValue() {
        let url = AppConfig.parseBaseURL("not-a-url")
        #expect(url.absoluteString == "http://127.0.0.1:8080")
    }

    @Test("runtime baseURL has a valid scheme and host")
    func runtimeBaseURLIsValid() {
        let url = AppConfig.baseURL
        #expect(url.scheme == "http")
        #expect(url.host == "127.0.0.1")
        #expect(url.port == 8080)
    }
}
