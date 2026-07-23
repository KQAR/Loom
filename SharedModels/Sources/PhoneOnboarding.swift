import Foundation

/// Everything a phone needs to route traffic through Loom and trust its CA,
/// produced by the engine when phone onboarding is enabled. Foundation-only so
/// it crosses the TCA client boundary and can be shown in the status-bar panel.
///
/// The flow: the engine binds the proxy on the LAN, stands up a small
/// provisioning HTTP server (serving the CA + an iOS `.mobileconfig` + a landing
/// page), and encodes the landing-page URL as a QR code. A phone on the same
/// Wi-Fi sets its manual HTTP proxy to `lanHost:proxyPort`, scans the QR, and
/// installs the CA from the page.
public struct PhoneOnboardingInfo: Equatable, Sendable, Codable {
    /// This machine's LAN IPv4 the phone should point at (e.g. `192.168.1.20`).
    public var lanHost: String
    /// The proxy port the phone sets as its manual HTTP/HTTPS proxy.
    public var proxyPort: Int
    /// The port the provisioning (CA download + landing page) server bound to.
    public var provisioningPort: Int
    /// The landing-page URL encoded in the QR code (`http://lanHost:provisioningPort/`).
    public var provisioningURL: URL
    /// Colon-separated uppercase SHA-256 of the root CA, for out-of-band verification.
    public var fingerprint: String
    /// The root CA's common name (e.g. `Loom Root CA`).
    public var commonName: String
    /// PNG bytes of the QR code for `provisioningURL`. Empty if QR generation failed.
    public var qrPNGData: Data

    public init(
        lanHost: String,
        proxyPort: Int,
        provisioningPort: Int,
        provisioningURL: URL,
        fingerprint: String,
        commonName: String,
        qrPNGData: Data
    ) {
        self.lanHost = lanHost
        self.proxyPort = proxyPort
        self.provisioningPort = provisioningPort
        self.provisioningURL = provisioningURL
        self.fingerprint = fingerprint
        self.commonName = commonName
        self.qrPNGData = qrPNGData
    }

    /// The `host:port` string the phone enters as its manual proxy.
    public var proxyAddress: String { "\(lanHost):\(proxyPort)" }
}
