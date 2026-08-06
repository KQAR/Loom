import Foundation
import LoomHelperShared
import Testing
@testable import PrivilegedHelperClient

/// The helper and the un-escalated path must run the *same* script. They used to be
/// two copies (one in `SystemProxyApplier`, one about to be written into the daemon),
/// which is how a privileged path and an unprivileged one drift into doing subtly
/// different work — undebuggable from either side, because each looks right alone.
@Suite struct SystemProxyScriptsTests {
    @Test func theApplierForwardsToTheSharedDefinition() {
        #expect(SystemProxyApplier.enableScript(host: "127.0.0.1", port: 9090)
            == SystemProxyScripts.enable(host: "127.0.0.1", port: 9090))
        for restore in [true, false] {
            #expect(SystemProxyApplier.disableScript(restoreQUIC: restore)
                == SystemProxyScripts.disable(restoreQUIC: restore))
        }
    }

    /// The pf fragment runs last on enable so the script's exit status is *its* status
    /// — that is how an un-escalated run learns the proxy landed but QUIC didn't, and
    /// escalates. Losing this is silent: admin users ran for months with HTTP/3 never
    /// blocked while the panel claimed otherwise.
    @Test func enableEndsWithTheQUICFragment() {
        let script = SystemProxyScripts.enable(host: "127.0.0.1", port: 9090)
        let quicIndex = try? #require(script.range(of: "loom_quic_enable"))
        #expect(quicIndex != nil)
        #expect(script.hasSuffix("loom_quic_enable"))
        #expect(script.contains("-setsecurewebproxy \"$svc\" 127.0.0.1 9090"))
    }

    /// Reverse order on disable, so QUIC is never left blocked without the proxy.
    @Test func disableRestoresQUICBeforeTurningTheProxyOff() throws {
        let script = SystemProxyScripts.disable(restoreQUIC: true)
        let restore = try #require(script.range(of: "loom_quic_disable"))
        let proxyOff = try #require(script.range(of: "-setwebproxystate"))
        #expect(restore.lowerBound < proxyOff.lowerBound)
        #expect(script.contains("exit $loom_quic_status"), "the pf status must survive as the script's status")
    }

    /// Nothing to restore → no pfctl at all, which is what keeps an admin user's
    /// toggle-off silent even with no helper installed.
    @Test func disableWithoutAQUICBlockCarriesNoPfctl() {
        let script = SystemProxyScripts.disable(restoreQUIC: false)
        #expect(!script.contains("pfctl"))
    }

    /// The crash-recovery path touches pf only. Loom does not hold the proxy setting
    /// in that state and must not write it.
    @Test func restoreQUICOnlyDoesNotTouchNetworksetup() {
        let script = SystemProxyScripts.restoreQUICOnly
        #expect(script.contains("loom_quic_disable"))
        #expect(!script.contains("networksetup"))
    }
}
