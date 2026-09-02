import Foundation
import LoomSharedModels

/// Moving the listener without stopping the proxy.
///
/// This is the **one write path for the port**, which is what makes it worth its own
/// file: the toolbar's address editor and the `set_proxy_port` MCP tool both land
/// here, and the invariants below are stated once instead of once per caller.
extension ProxyEngine {
    /// Move the HTTP listener (and the SOCKS one beside it) to `port`, keeping the
    /// interface they are already bound to.
    ///
    /// Four things it does that a naive stop-then-start does not, each of which was a
    /// defect on the app's own path before this existed:
    ///
    /// - **The interface survives.** A `start()` binds `127.0.0.1`, so restarting the
    ///   proxy to change its port silently closed it to the LAN and a phone that was
    ///   capturing stopped reaching it. Here the rebind is to `currentBindHost`.
    /// - **A refused move rolls back.** The stop has already happened by the time the
    ///   new bind is attempted, so throwing without restoring leaves a proxy that
    ///   every surface calls running with nothing listening.
    /// - **The SOCKS listener follows**, because the number a client was given for it
    ///   is derived from this one.
    /// - **Phone material is republished**, because the QR and the printed
    ///   `host:port` carry the port and both would now point at a closed socket.
    public func setListenPort(_ port: Int, socksPort: Int?) async throws -> ProxyStatus {
        // `0` means "let the kernel pick", which is what `start(port:)` already
        // accepts and what an embedder or a test binds with. It is not offered to
        // either operator-facing entry point — the card and the tool schema both name
        // the range — so the rules apply to every port a human or an agent can ask
        // for, and this stays consistent with the other way in.
        if port != 0, let refusal = ListenPortRules.refusal(
            for: port,
            reserved: ReservedPorts.shared.snapshot(),
            inUseByLoom: Set(reverseProxyConfig.snapshot().compactMap(\.boundPort))
        ) {
            throw ProxyControlError.listenerUnavailable(refusal)
        }
        guard running else {
            // Nothing to move, and pretending otherwise would report a port no socket
            // is on. Starting is the caller's decision, not a side effect of this.
            throw ProxyControlError.listenerUnavailable(
                "The proxy is stopped — start it, and it will come up on the port you pick."
            )
        }
        guard port != boundPort || socksPort != requestedSOCKSPort else {
            return await status()
        }

        let previousPort = boundPort
        let previousSOCKS = requestedSOCKSPort
        let host = currentBindHost
        await server.stop()
        do {
            boundPort = try await bindServer(host: host, port: port)
        } catch {
            let failure = BindDiagnosis.describe(error, host: host, port: port)
            // Back to the port that was working. Losing *this* one too is the state
            // worth saying plainly: the listener is down and staying down.
            guard let restored = try? await bindServer(host: host, port: previousPort) else {
                running = false
                throw ProxyControlError.listenerUnavailable(
                    "\(failure) Loom could not return to \(host):\(previousPort) either, so the proxy is stopped."
                )
            }
            boundPort = restored
            throw ProxyControlError.listenerUnavailable(failure)
        }

        // Only after the HTTP bind has landed — a SOCKS listener moved for a port
        // change that then failed would be a second thing to put back.
        await socksServer.stop()
        boundSOCKSPort = nil
        requestedSOCKSPort = socksPort
        await startSOCKSIfRequested(host: host)
        if socksPort != nil, boundSOCKSPort == nil, previousSOCKS != nil {
            Log.proxy.error("SOCKS listener did not come back after the port change; see status().socksError")
        }

        // The QR encodes `http://lanHost:provisioningPort/` and the popover prints
        // `lanHost:proxyPort`. Both were published for the old port, and a phone
        // reading either would now be pointed at a closed socket.
        if phoneInfo != nil {
            _ = try? await startPhoneOnboarding()
        }
        return await status()
    }
}
