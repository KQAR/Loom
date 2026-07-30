import Foundation
import Testing
import LoomHelperProtocol
import LoomSharedModels
@testable import PrivilegedHelperClient

/// Covers the pure privileged-proxy logic that the root helper relies on, without
/// needing root or `networksetup`.
@Suite struct SystemProxyParsingTests {
    @Test func parseProxyOutput() {
        let output = """
        Enabled: Yes
        Server: 127.0.0.1
        Port: 9090
        """
        let parsed = SystemProxyParsing.parseProxyOutput(output)
        #expect(parsed.enabled)
        #expect(parsed.host == "127.0.0.1")
        #expect(parsed.port == 9090)
    }

    @Test func parseProxyOutput_disabled() {
        let parsed = SystemProxyParsing.parseProxyOutput("Enabled: No\nServer:\nPort: 0")
        #expect(!parsed.enabled)
        #expect(parsed.port == 0)
    }

    @Test func parseServiceList_dropsDisclaimerAndDisabled() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        Wi-Fi
        *Thunderbolt Bridge
        USB 10/100/1000 LAN
        """
        #expect(SystemProxyParsing.parseServiceList(output) == ["Wi-Fi", "USB 10/100/1000 LAN"])
    }

    @Test func sanitizeBypassDomains_stripsUnsafeAndDedupes() {
        let input = ["*.local", " example.com ", "", "bad;rm -rf", "example.com", "a b", "10.0.0.0/8"]
        let clean = SystemProxyParsing.sanitizeBypassDomains(input)
        #expect(clean == ["*.local", "example.com", "10.0.0.0/8"])
        #expect(!clean.contains { $0.contains(";") || $0.contains(" ") })
    }

    @Test func proxyServiceState_pointsAtLoom() {
        let loom = ProxyServiceState(
            service: "Wi-Fi",
            httpEnabled: true, httpHost: "127.0.0.1", httpPort: 9090,
            httpsEnabled: true, httpsHost: "127.0.0.1", httpsPort: 9090
        )
        #expect(loom.pointsAtLoom(port: 9090))
        #expect(!loom.pointsAtLoom(port: 8888))

        let other = ProxyServiceState(service: "Wi-Fi", httpEnabled: true, httpHost: "10.0.0.1", httpPort: 8080)
        #expect(!other.pointsAtLoom(port: 9090))
    }

    /// The `SCDynamicStoreCopyProxies` key names are the part that breaks silently if
    /// it drifts — a typo reads as "no proxy set", which looks exactly like the state
    /// Loom is trying to detect. Exercised against the dictionary shape macOS returns,
    /// with no real dynamic store involved.
    @Test func snapshotFromDynamicStoreShape_readsTheRightKeys() {
        let pointing: [String: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 9090,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 9090,
            "ExceptionsList": ["localhost", "127.0.0.1", "*.local"],
        ]
        #expect(SystemProxyMonitor.snapshot(from: pointing).routing(loomPort: 9090) == .loom)
        // Same settings, different Loom port — Loom rebinds (phone onboarding), and a
        // proxy pointed at the old port is not routing to us.
        #expect(SystemProxyMonitor.snapshot(from: pointing).routing(loomPort: 8888)
            == .other(host: "127.0.0.1", port: 9090))

        // HTTPS disabled → not fully ours: every https:// request would bypass Loom.
        var httpOnly = pointing
        httpOnly["HTTPSEnable"] = 0
        #expect(SystemProxyMonitor.snapshot(from: httpOnly).routing(loomPort: 9090)
            == .other(host: "127.0.0.1", port: 9090))

        // Another proxy app owns it — reported as such, not as "off".
        let other: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 8888]
        #expect(SystemProxyMonitor.snapshot(from: other).routing(loomPort: 9090)
            == .other(host: "127.0.0.1", port: 8888))

        // Proxies off entirely (empty dict).
        #expect(SystemProxyMonitor.snapshot(from: [:]).routing(loomPort: 9090) == .off)
    }

    @Test func proxyBackup_codableRoundTrip() throws {
        let backup = ProxyBackup(
            services: [ProxyServiceState(service: "Wi-Fi", httpEnabled: true, httpHost: "127.0.0.1", httpPort: 9090, bypassDomains: ["*.local"])],
            ownerPID: 4242,
            loomPort: 9090,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try PropertyListEncoder().encode(backup)
        let decoded = try PropertyListDecoder().decode(ProxyBackup.self, from: data)
        #expect(decoded == backup)
    }
}
