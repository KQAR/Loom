import XCTest
@testable import ProxyCore

final class UserAgentParserTests: XCTestCase {
    func test_iphoneSafari() {
        let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        let r = UserAgentParser.parse(ua)
        XCTAssertEqual(r.platform, "iOS")
        XCTAssertEqual(r.client, "Safari")
    }

    func test_androidChrome() {
        let ua = "Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        let r = UserAgentParser.parse(ua)
        XCTAssertEqual(r.platform, "Android") // Android wins over the Linux token
        XCTAssertEqual(r.client, "Chrome")     // Chrome wins over the Safari token
    }

    func test_macChrome() {
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        let r = UserAgentParser.parse(ua)
        XCTAssertEqual(r.platform, "macOS")
        XCTAssertEqual(r.client, "Chrome")
    }

    func test_edgeBeatsChrome() {
        let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0"
        let r = UserAgentParser.parse(ua)
        XCTAssertEqual(r.platform, "Windows")
        XCTAssertEqual(r.client, "Edge")
    }

    func test_curl_hasClientButNoPlatform() {
        let r = UserAgentParser.parse("curl/8.4.0")
        XCTAssertNil(r.platform)
        XCTAssertEqual(r.client, "curl")
    }

    func test_customApp_fallsBackToLeadingToken() {
        let r = UserAgentParser.parse("MyCoolApp/2.1 (iPhone)")
        XCTAssertEqual(r.platform, "iOS")
        XCTAssertEqual(r.client, "MyCoolApp")
    }

    func test_emptyAndNil() {
        XCTAssertEqual(UserAgentParser.parse(nil).platform, nil)
        XCTAssertEqual(UserAgentParser.parse(nil).client, nil)
        XCTAssertEqual(UserAgentParser.parse("").client, nil)
    }
}
