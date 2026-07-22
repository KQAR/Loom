import Foundation
import XCTest
import SharedModels

/// Covers the pure privileged-proxy logic that the root helper relies on, without
/// needing root or `networksetup`.
final class SystemProxyParsingTests: XCTestCase {
    func test_parseProxyOutput() {
        let output = """
        Enabled: Yes
        Server: 127.0.0.1
        Port: 9090
        """
        let parsed = SystemProxyParsing.parseProxyOutput(output)
        XCTAssertTrue(parsed.enabled)
        XCTAssertEqual(parsed.host, "127.0.0.1")
        XCTAssertEqual(parsed.port, 9090)
    }

    func test_parseProxyOutput_disabled() {
        let parsed = SystemProxyParsing.parseProxyOutput("Enabled: No\nServer:\nPort: 0")
        XCTAssertFalse(parsed.enabled)
        XCTAssertEqual(parsed.port, 0)
    }

    func test_parseServiceList_dropsDisclaimerAndDisabled() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        Wi-Fi
        *Thunderbolt Bridge
        USB 10/100/1000 LAN
        """
        XCTAssertEqual(SystemProxyParsing.parseServiceList(output), ["Wi-Fi", "USB 10/100/1000 LAN"])
    }

    func test_sanitizeBypassDomains_stripsUnsafeAndDedupes() {
        let input = ["*.local", " example.com ", "", "bad;rm -rf", "example.com", "a b", "10.0.0.0/8"]
        let clean = SystemProxyParsing.sanitizeBypassDomains(input)
        XCTAssertEqual(clean, ["*.local", "example.com", "10.0.0.0/8"])
        XCTAssertFalse(clean.contains { $0.contains(";") || $0.contains(" ") })
    }

    func test_proxyServiceState_pointsAtLoom() {
        let loom = ProxyServiceState(
            service: "Wi-Fi",
            httpEnabled: true, httpHost: "127.0.0.1", httpPort: 9090,
            httpsEnabled: true, httpsHost: "127.0.0.1", httpsPort: 9090
        )
        XCTAssertTrue(loom.pointsAtLoom(port: 9090))
        XCTAssertFalse(loom.pointsAtLoom(port: 8888))

        let other = ProxyServiceState(service: "Wi-Fi", httpEnabled: true, httpHost: "10.0.0.1", httpPort: 8080)
        XCTAssertFalse(other.pointsAtLoom(port: 9090))
    }

    func test_effectiveProxiesPointAt_matchesSCDynamicStoreShape() {
        // The dictionary shape SCDynamicStoreCopyProxies returns.
        let pointing: [String: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 9090,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 9090,
            "ExceptionsList": ["localhost", "127.0.0.1", "*.local"],
        ]
        XCTAssertTrue(SystemProxyParsing.effectiveProxiesPoint(at: "127.0.0.1", port: 9090, in: pointing))
        XCTAssertFalse(SystemProxyParsing.effectiveProxiesPoint(at: "127.0.0.1", port: 8888, in: pointing))

        // HTTPS disabled → not fully ours.
        var httpOnly = pointing
        httpOnly["HTTPSEnable"] = 0
        XCTAssertFalse(SystemProxyParsing.effectiveProxiesPoint(at: "127.0.0.1", port: 9090, in: httpOnly))

        // Someone else's proxy.
        let other: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "10.0.0.1", "HTTPPort": 8080]
        XCTAssertFalse(SystemProxyParsing.effectiveProxiesPoint(at: "127.0.0.1", port: 9090, in: other))

        // Proxies off entirely (empty dict).
        XCTAssertFalse(SystemProxyParsing.effectiveProxiesPoint(at: "127.0.0.1", port: 9090, in: [:]))
    }

    func test_proxyBackup_codableRoundTrip() throws {
        let backup = ProxyBackup(
            services: [ProxyServiceState(service: "Wi-Fi", httpEnabled: true, httpHost: "127.0.0.1", httpPort: 9090, bypassDomains: ["*.local"])],
            ownerPID: 4242,
            loomPort: 9090,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try PropertyListEncoder().encode(backup)
        let decoded = try PropertyListDecoder().decode(ProxyBackup.self, from: data)
        XCTAssertEqual(decoded, backup)
    }
}
