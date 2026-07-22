import XCTest
@testable import ProxyCore

/// Regression: the forwarding session must never honor system proxy settings.
/// With Loom installed as the system proxy, a proxy-following URLSession routes
/// Loom's own upstream requests back into Loom — an infinite self-proxy loop
/// that shows up as duplicate flows, cascading errors, and huge durations.
final class UpstreamSessionTests: XCTestCase {
    func test_forwardingSession_bypassesSystemProxy() {
        let proxies = HTTPUtil.session.configuration.connectionProxyDictionary
        XCTAssertNotNil(proxies, "nil means 'use system proxy settings' — must be explicitly empty")
        XCTAssertEqual(proxies?.isEmpty, true, "forwarding must connect upstream directly, never via a proxy")
    }
}
