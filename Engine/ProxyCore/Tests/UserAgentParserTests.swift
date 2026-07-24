import Testing
@testable import ProxyCore

/// Swift Testing beachhead: this suite was the migration pattern for the pure,
/// table-driven tests. Runs in ProxyCore's Swift 5 language mode alongside the
/// remaining XCTest suites (both frameworks coexist in one target).
@Suite struct UserAgentParserTests {
    struct Case: CustomTestStringConvertible {
        let name: String
        let ua: String
        let platform: String?
        let client: String?
        var testDescription: String { name }
    }

    @Test(arguments: [
        Case(name: "iPhone Safari",
             ua: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
             platform: "iOS", client: "Safari"),
        // Android wins over the Linux token; Chrome wins over the Safari token.
        Case(name: "Android Chrome",
             ua: "Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
             platform: "Android", client: "Chrome"),
        Case(name: "Mac Chrome",
             ua: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
             platform: "macOS", client: "Chrome"),
        // Edge's `Edg/` token beats the Chrome token it also carries.
        Case(name: "Edge beats Chrome",
             ua: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0",
             platform: "Windows", client: "Edge"),
        Case(name: "curl: client, no platform", ua: "curl/8.4.0", platform: nil, client: "curl"),
        Case(name: "custom app falls back to leading token",
             ua: "MyCoolApp/2.1 (iPhone)", platform: "iOS", client: "MyCoolApp"),
    ])
    func parses(_ c: Case) {
        let result = UserAgentParser.parse(c.ua)
        #expect(result.platform == c.platform)
        #expect(result.client == c.client)
    }

    @Test func emptyAndNil() {
        #expect(UserAgentParser.parse(nil).platform == nil)
        #expect(UserAgentParser.parse(nil).client == nil)
        #expect(UserAgentParser.parse("").client == nil)
    }
}
