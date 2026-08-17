import Foundation

/// A captured failure with a stable machine-readable classification.
///
/// `message` remains the human-facing summary and preserves the public API used by
/// existing embedders. `code` and `detail` are additive: rows written before Loom
/// classified failures decode with both absent rather than being guessed at.
public struct FlowError: Equatable, Codable, Sendable {
    /// Failure categories whose distinction changes the operator's next action.
    public enum Code: String, Codable, Sendable, CaseIterable {
        /// The peer sent a certificate-related TLS alert after Loom offered its leaf.
        case clientCertificateRejected
        /// The peer closed after starting TLS, without a conclusive alert.
        case clientHandshakeAborted
        /// TLS failed for another reason before an HTTP request existed.
        case clientHandshakeFailed
        /// Loom's intercepted-protocol codec could not continue safely.
        case interceptedProtocolError
    }

    public var message: String
    public var code: Code?
    /// Underlying library text retained for diagnosis, never used as the category.
    public var detail: String?

    public init(_ message: String, code: Code? = nil, detail: String? = nil) {
        self.message = message
        self.code = code
        self.detail = detail
    }
}

public extension Flow {
    /// Whether a record is an HTTP exchange or a connection-level diagnostic.
    enum RecordKind: String, Codable, Sendable, CaseIterable {
        case exchange
        case tunnel
    }

    /// One connection Loom relayed or failed before an HTTP exchange existed.
    struct TunnelDiagnostic: Equatable, Codable, Sendable {
        public var host: String
        public var port: Int
        /// Nil only for a legacy CONNECT row whose exact pass-through reason was
        /// never persisted. New records always provide the reason.
        public var reason: TunnelReason?
        public var detail: String?

        public init(host: String, port: Int, reason: TunnelReason?, detail: String? = nil) {
            self.host = host
            self.port = port
            self.reason = reason
            self.detail = detail
        }
    }

    /// The explicit kind for new records, with a strict compatibility projection
    /// for CONNECT rows persisted before `tunnelDiagnostic` existed.
    var recordKind: RecordKind {
        effectiveTunnelDiagnostic == nil ? .exchange : .tunnel
    }

    /// A typed tunnel record, including the conservative projection of a legacy row.
    ///
    /// The legacy success reason stays nil because a CONNECT row cannot distinguish
    /// `notInScope` from `excluded`. A failed legacy row can distinguish the two
    /// failure families from its existing message without inventing finer evidence.
    var effectiveTunnelDiagnostic: TunnelDiagnostic? {
        if let tunnelDiagnostic { return tunnelDiagnostic }
        guard request.method.caseInsensitiveCompare("CONNECT") == .orderedSame else {
            return nil
        }
        let url = URL(string: request.url)
        let host = url?.host ?? URLHost.host(ofURLString: request.url) ?? request.url

        let reason: TunnelReason?
        if flowError?.code == .interceptedProtocolError
            || error?.localizedCaseInsensitiveContains("could not read the HTTP/2 connection") == true {
            reason = .protocolError
        } else if error != nil {
            reason = .clientHandshakeFailed
        } else {
            reason = nil
        }
        return TunnelDiagnostic(
            host: host,
            port: url?.port ?? 443,
            reason: reason,
            detail: flowError?.detail
        )
    }
}
