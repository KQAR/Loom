import Testing
import Foundation
@testable import ProxyCore
import SharedModels

@Suite struct SourceAppTests {
    @Test func groupingKey_prefersBundleID() {
        let app = SourceApp(name: "Google Chrome", bundleID: "com.google.Chrome", bundlePath: "/Applications/Google Chrome.app", pid: 42)
        #expect(app.groupingKey == "com.google.Chrome")
    }

    @Test func groupingKey_fallsBackToName() {
        let cli = SourceApp(name: "curl", pid: 99) // no bundle id
        #expect(cli.groupingKey == "curl")
    }

    @Test func codableRoundTrip() throws {
        let app = SourceApp(name: "Safari", bundleID: "com.apple.Safari", bundlePath: "/Applications/Safari.app", pid: 7)
        let flow = Flow(
            request: CapturedRequest(method: "GET", url: "https://example.com/", headers: []),
            startedAt: Date(timeIntervalSince1970: 0),
            sourceApp: app
        )
        let data = try JSONEncoder().encode(flow)
        let decoded = try JSONDecoder().decode(Flow.self, from: data)
        #expect(decoded.sourceApp == app)
    }

    @Test func resolve_nilPorts_returnsNil() {
        // The NIO convenience must no-op cleanly when a port is missing.
        #expect(ProcessResolver.resolve(sourcePort: nil, proxyPort: 9090) == nil)
        #expect(ProcessResolver.resolve(sourcePort: 50000, proxyPort: nil) == nil)
        #expect(ProcessResolver.resolve(sourcePort: 0, proxyPort: 9090) == nil)
    }
}
