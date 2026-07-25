import Foundation
import LoomProxyCore
import LoomSharedModels
import PrivilegedHelperClient

/// Gives the MCP server the one thing it can't reach on its own: whether this Mac's
/// traffic is routed through Loom, and the switch for it.
///
/// The engine can't do this itself — `networksetup` and the QUIC pf anchor live in
/// the client layer, and the dependency direction is one-way (App → Features →
/// Clients → Engine). So the app owns the adapter and injects it, which is also why
/// `SystemRoutingControlling` is a protocol in SharedModels rather than a method on
/// `ProxyEngine`.
///
/// The port isn't fixed at construction: `setSystemProxy` writes `127.0.0.1:<port>`
/// into the system settings, and the proxy's bound port is whatever the engine ended
/// up with (phone onboarding rebinds it). Both calls read it live so the settings can
/// never point at a port Loom isn't listening on.
struct SystemRoutingAdapter: SystemRoutingControlling {
    private let helper: PrivilegedHelperClient

    init(helper: PrivilegedHelperClient = .liveValue) {
        self.helper = helper
    }

    func isSystemProxyActive() async -> Bool {
        let port = await ProxyEngine.shared.status().port
        return await helper.isSystemProxyActive(port)
    }

    func setSystemProxy(enabled: Bool) async -> SystemRoutingResult {
        let port = await ProxyEngine.shared.status().port
        let outcome = await helper.setSystemProxy(enabled, port)
        return SystemRoutingResult(ok: outcome.ok, message: outcome.message)
    }
}
