import Foundation
import LoomSharedModels
import NIOCore
import NIOSSL
import NIOTLS

/// Records the case where Loom presented its leaf and the **client refused it**.
///
/// Loom already reports the mirror image — a *server* that refuses Loom's upstream
/// handshake becomes an `UpstreamTLSError` on the flow. The client-facing side had
/// nothing: `NIOSSLServerHandler` fired the error, it travelled to the end of a
/// pipeline that had not been configured yet, and that was the end of it. No flow
/// (there is no request — the client hung up before sending one), no tunnelled-host
/// entry (nothing was relayed), no log. From every surface Loom offers, such a host
/// simply does not exist.
///
/// That is the failure this project already fixed once for pass-throughs and left
/// open here, and it is worse in one specific way: an unread relay still *works*,
/// while a refused handshake means the operator's request never happened. They see
/// a broken page and a capture that denies the host was ever contacted.
///
/// Found on the wire rather than by reading code: four connections to two CDN
/// origins, each `CONNECT` → `200` → ClientHello → Loom's certificate →
/// `14 03 03 00 01 01` `17 03 03 00 13 …` → FIN. A change_cipher_spec (TLS 1.3
/// compatibility mode, RFC 8446 §5.1) followed by a 19-byte encrypted record —
/// 2 bytes of alert plus a content-type byte plus a 16-byte AEAD tag, which is
/// exactly the shape of an encrypted fatal alert (RFC 8446 §5.2, §6.2). Pinned
/// hosts, invisible.
// @unchecked Sendable: event-loop confined, no lock — see ProxyCore/CLAUDE.md
// § Sendable escape hatches for what that forbids inside a `Task {}`.
final class ClientTLSFailureReporter: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let host: String
    private let port: Int
    private let log: TunneledHostLog
    /// Where the failed connection is recorded as a flow. Optional so the reporter
    /// can be exercised on its own — every production path supplies one.
    private let store: FlowStore?
    /// Shared with `ClientTLSAbortReporter` below the SSL handler: that one sees the
    /// bytes and the connection ending, this one sees NIOSSL's events. Either may be
    /// the first to learn the interception failed, and the attempt is what keeps them
    /// to one report between them.
    private let attempt: ClientTLSAttempt
    /// When the client connected, so the row carries a duration rather than a
    /// zero: a handshake that fails slowly and one that fails instantly are
    /// different problems.
    private let startedAt = Date()
    init(
        host: String, port: Int, attempt: ClientTLSAttempt = ClientTLSAttempt(),
        log: TunneledHostLog = .shared, store: FlowStore? = nil
    ) {
        self.host = host
        self.port = port
        self.attempt = attempt
        self.log = log
        self.store = store
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event {
            attempt.handshakeCompleted = true
            log.recordClientSuccess(host: host, port: port)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        report(error, client: context.channel)
        context.fireErrorCaught(error)
    }

    private func report(_ error: Error, client: Channel?) {
        guard !attempt.handshakeCompleted, !attempt.reported else { return }
        guard Self.isHandshakeFailure(error) else { return }
        let detail = Self.describe(error)
        let alert = TLSClientAlert.parse(detail)
        let code = alert?.failureCode ?? .clientHandshakeFailed
        let summary = alert?.summary
            ?? "Client TLS handshake failed before an HTTP request was sent"
        // Recorded in both places — the console's aggregate and a row in the request
        // table. Without the row a refused handshake is a client-side certificate
        // error against a capture holding nothing for that host at all, which is what
        // "Loom lost it" and "the app never asked" look like alike.
        attempt.report(
            host: host, port: port, code: code, detail: detail, tlsAlert: alert,
            summary: "\(summary) — \(detail)",
            client: client, startedAt: startedAt, log: log, store: store
        )
        Log.tls.error("""
        Client TLS handshake failed for \(self.host, privacy: .public):\(self.port, privacy: .public) \
        — \(detail, privacy: .public). Classification: \(code.rawValue, privacy: .public).
        """)
    }

    /// Only a TLS handshake failure counts.
    ///
    /// Deliberately narrow: an unclean shutdown is a client that hung up mid-stream
    /// (ordinary, and not a certificate verdict), and an I/O error is the network.
    /// Recording either as "the client refused Loom" would put noise on the one
    /// surface an operator reads to find out why a host is missing.
    private static func isHandshakeFailure(_ error: Error) -> Bool {
        guard let sslError = error as? NIOSSLError else { return false }
        if case .handshakeFailed = sslError { return true }
        return false
    }

    /// The BoringSSL / NIOSSL text. Classification is `TLSClientAlert.parse`,
    /// which does **not** treat `certificate_unknown` as proof of pinning or of
    /// an invalid leaf — those two look identical on the wire.
    static func describe(_ error: Error) -> String {
        guard case let .handshakeFailed(underlying)? = error as? NIOSSLError else {
            return String(describing: error)
        }
        return String(describing: underlying)
    }

    /// Map a handshake error string to a flow code. `certificate_unknown` is
    /// its own inconclusive code; only `unknown_ca` / `bad_certificate` are a
    /// rejection of the cert itself. An EOF or protocol mismatch is not either.
    static func failureCode(forDetail detail: String) -> FlowError.Code {
        TLSClientAlert.parse(detail)?.failureCode ?? .clientHandshakeFailed
    }
}
