import Foundation
import LoomSharedModels

/// Making the proxy reachable from a phone: rebinding the listener to the LAN,
/// serving the CA + iOS profile from a provisioning server, and publishing the QR
/// code that points at it. Not part of `ProxyControlling` — an extra capability
/// on the engine, reusable by any embedder.
extension ProxyEngine {
    /// Make the proxy reachable from a phone and publish everything the phone
    /// needs to route through it and trust the CA. Not part of `ProxyControlling`
    /// — an extra public capability on the engine (like `caCertificateDER()`),
    /// reusable by any embedder.
    ///
    /// Rebinds the proxy to `0.0.0.0` (LAN-reachable), starts a provisioning
    /// server serving the CA + iOS profile + a landing page, and encodes that
    /// page's URL as a QR code. Idempotent: called again it tears down the prior
    /// provisioning server and republishes (e.g. after the LAN IP changed).
    ///
    /// - Parameter provisioningPort: the download-server port; `0` (default) lets
    ///   the OS pick one.
    @discardableResult
    public func startPhoneOnboarding(provisioningPort: Int = 0) async throws -> PhoneOnboardingInfo {
        // Reentrancy guard: the body awaits several times between tearing down the
        // old provisioning server and publishing the new one. Two concurrent calls
        // would each stop the old server, each start a new one on the same port
        // (one failing), and leave `provisioning` pointing at whichever won the
        // last assignment — possibly an already-stopped server.
        guard !startingPhoneOnboarding else {
            throw ProxyControlError.phoneOnboardingUnavailable("phone onboarding is already starting")
        }
        startingPhoneOnboarding = true
        defer { startingPhoneOnboarding = false }

        guard let ca = ensureCA() else {
            throw ProxyControlError.certificateUnavailable("root CA could not be generated")
        }
        guard let lanHost = LANAddress.primaryIPv4() else {
            throw ProxyControlError.phoneOnboardingUnavailable("no LAN IPv4 address — is this machine on Wi-Fi/Ethernet?")
        }

        // The phone can only reach the proxy if it isn't bound to loopback.
        if !running {
            _ = try await start(port: boundPort, host: "0.0.0.0")
        } else if currentBindHost != "0.0.0.0" {
            try await rebind(host: "0.0.0.0")
        }

        // Fresh provisioning server (drop any prior one).
        await provisioning?.stop()
        let content = ProvisioningContent(
            caPEM: ca.caCertificatePEM(),
            caDER: ca.caCertificateDER(),
            fingerprint: ca.sha256Fingerprint,
            commonName: CertificateAuthority.commonName,
            proxyHost: lanHost,
            proxyPort: boundPort
        )
        let server = ProvisioningServer(group: group)
        let provPort = try await server.start(host: "0.0.0.0", port: provisioningPort, content: content)
        provisioning = server

        guard let url = URL(string: "http://\(lanHost):\(provPort)/") else {
            await server.stop()
            provisioning = nil
            throw ProxyControlError.phoneOnboardingUnavailable("could not form provisioning URL")
        }

        let info = PhoneOnboardingInfo(
            lanHost: lanHost,
            proxyPort: boundPort,
            provisioningPort: provPort,
            provisioningURL: url,
            fingerprint: ca.sha256Fingerprint,
            commonName: CertificateAuthority.commonName,
            qrPNGData: QRCode.generate(from: url.absoluteString)?.pngData ?? Data()
        )
        phoneInfo = info
        return info
    }

    /// Stop serving provisioning material and return the proxy to loopback-only.
    ///
    /// **Throws rather than swallowing the rebind**, and does it *before* tearing the
    /// material down, so a failure leaves everything as it was. `try?` here meant a
    /// loopback bind Loom lost (something else took the port while the listener was on
    /// `0.0.0.0`) left the switch reading "off" with the proxy still answering the whole
    /// LAN — a promise about who can reach this machine, quietly not kept.
    ///
    /// The order is the other half: with the teardown first, that same failure left the
    /// provisioning server stopped and `phoneInfo` cleared while the listener stayed on
    /// the LAN, which is neither state the operator asked for.
    public func stopPhoneOnboarding() async throws {
        if running, currentBindHost != "127.0.0.1" {
            // A failed move puts the listener back on `0.0.0.0` (see `rebind`), which
            // is what makes throwing honest: LAN is still on, and the switch must say so.
            try await rebind(host: "127.0.0.1")
        }
        await provisioning?.stop()
        provisioning = nil
        phoneInfo = nil
    }

    /// The current onboarding info, or `nil` when phone onboarding is inactive.
    public func phoneOnboardingInfo() async -> PhoneOnboardingInfo? {
        phoneInfo
    }

    /// Move the running listeners to a different interface on the same ports. The
    /// flow store, CA and rules are untouched — only the accepting sockets move.
    ///
    /// The SOCKS listener moves with the HTTP one: a phone configured to route
    /// through Loom can be pointed at either, and leaving SOCKS on loopback would
    /// make it silently unreachable from the device this rebind exists to serve.
    ///
    /// **A failed move puts the listener back.** The stop has already happened by the
    /// time the new bind is attempted, so throwing from here used to leave the engine
    /// `running` with nothing listening at all — every surface reporting a healthy
    /// proxy on a port where no socket exists, and the capture silently over. The
    /// measured case was another proxy holding `*:9090` (IPv6 wildcard): Loom's
    /// `127.0.0.1` bind had succeeded, and only the move to `0.0.0.0` collided.
    ///
    /// The SOCKS listener needs no rollback: it is not touched until the HTTP bind
    /// has succeeded, so a failure leaves it where it already was.
    private func rebind(host: String) async throws {
        guard running else { return }
        let previous = currentBindHost
        await server.stop()
        do {
            boundPort = try await bindServer(host: host)
        } catch {
            let failure = BindDiagnosis.describe(error, host: host, port: boundPort)
            do {
                boundPort = try await bindServer(host: previous)
                // Set *after* the roll-back, which cleared it: unlike a refused port
                // change (where the listener ends up exactly where it should be), a
                // refused move to `0.0.0.0` leaves a standing disagreement — LAN
                // device connection is on and the network cannot reach Loom. An agent
                // reading `lanReachable: false` otherwise cannot tell that from the
                // switch simply being off.
                listenerFailure = failure
                throw ProxyControlError.listenerUnavailable(failure)
            } catch let restoreError as ProxyControlError {
                throw restoreError
            } catch {
                // Both binds failed, which is the state worth stating plainly: the
                // listener is down and staying down until something frees a port.
                running = false
                throw ProxyControlError.listenerUnavailable(
                    "\(failure) Loom could not return to \(previous):\(boundPort) either, so the proxy is stopped."
                )
            }
        }
        await socksServer.stop()
        boundSOCKSPort = nil
        await startSOCKSIfRequested(host: host)
        currentBindHost = host
    }

    /// The one place the accepting socket's configuration is spelled out, so a move,
    /// a roll-back and a port change cannot drift into binding differently.
    func bindServer(host: String, port: Int? = nil) async throws -> Int {
        // A wildcard bind coexists with a loopback one and loses every local client
        // to it, silently — see `LoopbackProbe`. Asked here so both writers of the
        // listener (the LAN switch and a port change) get the check.
        if host == "0.0.0.0", LoopbackProbe.isTaken(port: port ?? boundPort) {
            listenerFailure = """
            127.0.0.1:\(port ?? boundPort) is held by another process, so Loom did not take the \
            LAN binding — this Mac's own clients would have reached that process instead.
            """
            throw ProxyControlError.listenerUnavailable("""
            127.0.0.1:\(port ?? boundPort) is held by another process. Loom can bind every \
            interface anyway, but the kernel gives loopback connections to the more specific \
            listener — so this Mac's own clients would reach that process instead, with nothing \
            saying so. Pick another port, or stop the one holding it.
            """)
        }
        let bound = try await server.start(
            host: host,
            port: port ?? boundPort,
            store: store,
            forwarder: forwarder,
            ca: ensureCA(),
            config: config,
            observeTunnels: lastObserveTunnels
        )
        // Cleared by the bind that lands, never before one is attempted: an entry
        // that outlives its condition and one that vanishes before it is fixed are
        // the same defect from opposite sides.
        listenerFailure = nil
        return bound
    }
}
