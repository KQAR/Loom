import Foundation
import Testing
import LoomSharedModels

/// One definition of "where does this Mac's traffic go", used by the panel row, the
/// quit-time cleanup decision, and `get_proxy_status`. It replaced a boolean that
/// collapsed *off* and *another proxy app owns it* into the same answer — which is the
/// difference between "press the switch" and "quit Charles first".
@Suite struct SystemProxyRoutingTests {
    private func snapshot(http: (String, Int)?, https: (String, Int)?) -> SystemProxySnapshot {
        SystemProxySnapshot(
            httpEnabled: http != nil, httpHost: http?.0 ?? "", httpPort: http?.1 ?? 0,
            httpsEnabled: https != nil, httpsHost: https?.0 ?? "", httpsPort: https?.1 ?? 0
        )
    }

    @Test func bothProtocolsOnLoomIsLoom() {
        let s = snapshot(http: ("127.0.0.1", 9090), https: ("127.0.0.1", 9090))
        #expect(s.routing(loomPort: 9090) == .loom)
    }

    @Test func nothingEnabledIsOff() {
        #expect(SystemProxySnapshot.off.routing(loomPort: 9090) == .off)
    }

    @Test func anotherProxyIsReportedWithItsAddress() {
        let s = snapshot(http: ("127.0.0.1", 8888), https: ("127.0.0.1", 8888))
        #expect(s.routing(loomPort: 9090) == .other(host: "127.0.0.1", port: 8888))
    }

    /// Half-routed is not routed. Charles keeping HTTPS means every `https://` request
    /// bypasses Loom, which is precisely the empty-capture case this answers — so
    /// reporting `.loom` because HTTP happens to be ours would be a lie.
    @Test func httpsOnAnotherProxyIsNotLoom() {
        let s = snapshot(http: ("127.0.0.1", 9090), https: ("127.0.0.1", 8888))
        #expect(s.routing(loomPort: 9090) != .loom)
    }

    /// A half-applied state pointing at Loom's own address still isn't fully routed.
    /// `.other` reports where the enabled half goes, even when that's us.
    @Test func onlyHTTPEnabledIsNotLoomEvenAtLoomsAddress() {
        let s = snapshot(http: ("127.0.0.1", 9090), https: nil)
        #expect(s.routing(loomPort: 9090) == .other(host: "127.0.0.1", port: 9090))
    }

    /// Loom rebinds its port (phone onboarding). A proxy still aimed at the old port is
    /// not routing to Loom, and saying so is what stops "why is the capture empty".
    @Test func aStalePortIsNotLoom() {
        let s = snapshot(http: ("127.0.0.1", 9090), https: ("127.0.0.1", 9090))
        #expect(s.routing(loomPort: 9091) == .other(host: "127.0.0.1", port: 9090))
    }

    /// Loom binds loopback only, so a same-port proxy on another host is someone else's
    /// (a corporate proxy, a VM gateway).
    @Test func aNonLoopbackHostIsNotLoom() {
        let s = snapshot(http: ("10.0.0.1", 9090), https: ("10.0.0.1", 9090))
        #expect(s.routing(loomPort: 9090) == .other(host: "10.0.0.1", port: 9090))
    }

    /// When only HTTPS is set, that's the address to report — not an empty HTTP host.
    @Test func httpsOnlyReportsTheHTTPSAddress() {
        let s = snapshot(http: nil, https: ("127.0.0.1", 8888))
        #expect(s.routing(loomPort: 9090) == .other(host: "127.0.0.1", port: 8888))
    }
}
