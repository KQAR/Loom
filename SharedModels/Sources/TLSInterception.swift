import Foundation

/// Snapshot of the man-in-the-middle root CA's state, surfaced to the human
/// (status-bar fault card) and to the agent (`get_certificate_status`).
public struct CertificateStatus: Equatable, Codable, Sendable {
    /// A root CA exists (generated on first launch and persisted).
    public var isGenerated: Bool
    /// Best-effort: the CA is present as a trusted anchor in a system/user trust
    /// store. HTTPS interception only works for clients that trust this anchor.
    public var isTrusted: Bool
    public var commonName: String?
    /// Colon-separated uppercase SHA-256 of the CA certificate (DER).
    public var sha256Fingerprint: String?
    public var notAfter: Date?
    /// Filesystem path the CA PEM was last exported to, if any.
    public var exportedPEMPath: String?

    public init(
        isGenerated: Bool,
        isTrusted: Bool,
        commonName: String? = nil,
        sha256Fingerprint: String? = nil,
        notAfter: Date? = nil,
        exportedPEMPath: String? = nil
    ) {
        self.isGenerated = isGenerated
        self.isTrusted = isTrusted
        self.commonName = commonName
        self.sha256Fingerprint = sha256Fingerprint
        self.notAfter = notAfter
        self.exportedPEMPath = exportedPEMPath
    }

    public static let notGenerated = CertificateStatus(isGenerated: false, isTrusted: false)

    /// The setup stage the human is at, so the UI can drive one clear next step.
    public var trustState: CertificateTrustState {
        if !isGenerated { return .notGenerated }
        return isTrusted ? .trusted : .notTrusted
    }
}

/// Where the root CA is in the "generate → trust → decrypt" journey. Drives the
/// certificate card's icon, copy, and which action is offered next.
public enum CertificateTrustState: Equatable, Sendable {
    /// No CA yet (generated lazily on first interception).
    case notGenerated
    /// CA exists but isn't trusted for TLS, so decryption would fail.
    case notTrusted
    /// Trusted system-wide — interception works.
    case trusted

    public var isReady: Bool { self == .trusted }

    public var title: String {
        switch self {
        case .notGenerated: return "Certificate not generated"
        case .notTrusted: return "Trust required"
        case .trusted: return "CA trusted"
        }
    }

    public var message: String {
        switch self {
        case .notGenerated:
            return "Loom's root CA is created the first time you intercept. Turn SSL on to generate it."
        case .notTrusted:
            return "The root CA exists but macOS hasn't trusted it for TLS. Install & trust it to decrypt HTTPS."
        case .trusted:
            return "HTTPS interception is ready for hosts in scope."
        }
    }

    public var systemImageName: String {
        switch self {
        case .notGenerated: return "xmark.seal"
        case .notTrusted: return "exclamationmark.triangle.fill"
        case .trusted: return "checkmark.seal.fill"
        }
    }
}

/// Which hosts Loom decrypts (MITM) vs. blind-tunnels. A host is intercepted
/// only when interception is `enabled`, it matches an `include` glob, and it
/// matches no `exclude` glob. `exclude` doubles as the pinned / pass-through
/// list: cert-pinned hosts belong here so they keep working untouched.
public struct SSLScope: Equatable, Codable, Sendable {
    public var enabled: Bool
    public var include: [String]
    public var exclude: [String]

    public init(enabled: Bool = false, include: [String] = [], exclude: [String] = []) {
        self.enabled = enabled
        self.include = include
        self.exclude = exclude
    }

    public static let disabled = SSLScope()

    /// Should the given host be MITM-decrypted under this scope?
    public func shouldIntercept(host: String) -> Bool {
        guard enabled else { return false }
        guard include.contains(where: { Self.matches(pattern: $0, host: host) }) else { return false }
        if exclude.contains(where: { Self.matches(pattern: $0, host: host) }) { return false }
        return true
    }

    /// Case-insensitive glob match where `*` stands for any run of characters.
    /// `*.example.com` matches `api.example.com` but not the bare `example.com`;
    /// a bare `*` matches everything.
    public static func matches(pattern rawPattern: String, host rawHost: String) -> Bool {
        let pattern = rawPattern.lowercased()
        let host = rawHost.lowercased()
        if pattern == host { return true }
        guard pattern.contains("*") else { return false }

        let segments = pattern.components(separatedBy: "*")
        var index = host.startIndex

        // A leading non-"*" segment must anchor at the start.
        if let first = segments.first, !first.isEmpty {
            guard host.hasPrefix(first) else { return false }
            index = host.index(index, offsetBy: first.count)
        }
        // Interior segments must appear in order, after the prefix.
        for segment in segments.dropFirst().dropLast() where !segment.isEmpty {
            guard let range = host.range(of: segment, range: index ..< host.endIndex) else { return false }
            index = range.upperBound
        }
        // A trailing non-"*" segment must anchor at the end *without overlapping*
        // what the prefix/interior already consumed — otherwise "ab*b" would match
        // the bare "ab" (prefix "ab" and suffix "b" reusing the same 'b').
        if segments.count > 1, let last = segments.last, !last.isEmpty {
            guard host.hasSuffix(last),
                  host.distance(from: index, to: host.endIndex) >= last.count
            else { return false }
        }
        return true
    }
}

/// The HTTPS-interception surface of the engine — certificate state and the
/// SSL-proxying scope. Composed into `ProxyControlling` so both the MCP server
/// and the TCA client reach it through the one shared engine.
public protocol TLSInterceptControlling: Sendable {
    func certificateStatus() async -> CertificateStatus
    /// Write the root CA (PEM) to disk so the human can trust it; returns the path.
    func exportCACertificate() async throws -> URL
    func sslScope() async -> SSLScope
    func setSSLScope(_ scope: SSLScope) async
}
