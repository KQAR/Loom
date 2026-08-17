import Foundation

/// A certificate-related TLS alert the **client** sent after seeing Loom's leaf.
///
/// These are what BoringSSL named on the wire. They are not a diagnosis of *why*
/// the client refused: `certificate_unknown` is also what an app that ignores
/// user CAs, and a pinned client, both send. Loom records the alert; it does
/// not promote it to "the leaf is invalid" or "this host is pinned".
public enum TLSClientAlert: String, Codable, Sendable, CaseIterable {
    /// Alert 46. Inconclusive: the client did not accept the leaf.
    case certificateUnknown
    /// Alert 48. The client said it does not trust the issuing CA.
    case unknownCA
    /// Alert 42. The client said the leaf itself is malformed.
    case badCertificate

    /// Pull the alert out of a BoringSSL / NIOSSL handshake error string.
    public static func parse(_ detail: String) -> TLSClientAlert? {
        let lowered = detail.lowercased()
        // `unknown_ca` is not a substring of `certificate_unknown`; check the
        // specific CA alert first so a future looser match cannot swallow it.
        if lowered.contains("unknown_ca") { return .unknownCA }
        if lowered.contains("bad_certificate") { return .badCertificate }
        if lowered.contains("certificate_unknown") { return .certificateUnknown }
        return nil
    }

    /// Stable flow code. Only `unknown_ca` / `bad_certificate` are a rejection
    /// of the cert itself; `certificate_unknown` stays its own inconclusive code.
    public var failureCode: FlowError.Code {
        switch self {
        case .unknownCA, .badCertificate: .clientCertificateRejected
        case .certificateUnknown: .clientCertificateUnknown
        }
    }

    /// One-line summary for the request table and MCP. Must not claim a cause
    /// the alert does not prove.
    public var summary: String {
        switch self {
        case .certificateUnknown:
            "Client sent TLS alert certificate_unknown after seeing Loom's leaf. This does not prove the leaf is invalid — apps that ignore user CAs and pinned clients send the same alert"
        case .unknownCA:
            "Client does not trust Loom's CA (TLS alert unknown_ca)"
        case .badCertificate:
            "Client rejected Loom's leaf as malformed (TLS alert bad_certificate)"
        }
    }
}
