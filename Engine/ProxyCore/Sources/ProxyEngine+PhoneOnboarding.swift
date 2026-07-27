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
    public func stopPhoneOnboarding() async {
        await provisioning?.stop()
        provisioning = nil
        phoneInfo = nil
        if running, currentBindHost != "127.0.0.1" {
            try? await rebind(host: "127.0.0.1")
        }
    }

    /// The current onboarding info, or `nil` when phone onboarding is inactive.
    public func phoneOnboardingInfo() async -> PhoneOnboardingInfo? {
        phoneInfo
    }

    /// Move the running listener to a different interface on the same port. The
    /// flow store, CA and rules are untouched — only the accepting socket moves.
    private func rebind(host: String) async throws {
        guard running else { return }
        await server.stop()
        boundPort = try await server.start(
            host: host,
            port: boundPort,
            store: store,
            forwarder: forwarder,
            ca: ensureCA(),
            config: config,
            observeTunnels: lastObserveTunnels
        )
        currentBindHost = host
    }
}
