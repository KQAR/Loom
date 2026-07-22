import XCTest
@testable import ProxyCore
import SharedModels

final class SourceAppTests: XCTestCase {
    func test_groupingKey_prefersBundleID() {
        let app = SourceApp(name: "Google Chrome", bundleID: "com.google.Chrome", bundlePath: "/Applications/Google Chrome.app", pid: 42)
        XCTAssertEqual(app.groupingKey, "com.google.Chrome")
    }

    func test_groupingKey_fallsBackToName() {
        let cli = SourceApp(name: "curl", pid: 99) // no bundle id
        XCTAssertEqual(cli.groupingKey, "curl")
    }

    func test_codableRoundTrip() throws {
        let app = SourceApp(name: "Safari", bundleID: "com.apple.Safari", bundlePath: "/Applications/Safari.app", pid: 7)
        let flow = Flow(
            request: CapturedRequest(method: "GET", url: "https://example.com/", headers: []),
            startedAt: Date(timeIntervalSince1970: 0),
            sourceApp: app
        )
        let data = try JSONEncoder().encode(flow)
        let decoded = try JSONDecoder().decode(Flow.self, from: data)
        XCTAssertEqual(decoded.sourceApp, app)
    }

    func test_resolve_nilPorts_returnsNil() {
        // The NIO convenience must no-op cleanly when a port is missing.
        XCTAssertNil(ProcessResolver.resolve(sourcePort: nil, proxyPort: 9090))
        XCTAssertNil(ProcessResolver.resolve(sourcePort: 50000, proxyPort: nil))
        XCTAssertNil(ProcessResolver.resolve(sourcePort: 0, proxyPort: 9090))
    }
}
