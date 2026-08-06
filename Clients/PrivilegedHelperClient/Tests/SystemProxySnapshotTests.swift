import Foundation
import Testing
import LoomSharedModels
@testable import PrivilegedHelperClient

/// Covers reading the *effective* system proxy — the shipping path, with no real
/// dynamic store involved.
///
/// This file is what survives `SystemProxyParsingTests`. The rest of that suite
/// covered `SystemProxyParsing` / `ProxyServiceState` / `ProxyBackup`, which existed
/// only for the never-loaded root helper and went with it.
@Suite struct SystemProxySnapshotTests {
    /// The `SCDynamicStoreCopyProxies` key names are the part that breaks silently if
    /// it drifts — a typo reads as "no proxy set", which looks exactly like the state
    /// Loom is trying to detect. Exercised against the dictionary shape macOS returns.
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
}
