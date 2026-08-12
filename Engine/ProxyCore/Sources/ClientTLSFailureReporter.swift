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
    /// Set by NIOSSL's own handshake event. After it, an error is something else —
    /// a broken request, a dropped connection — and belongs to whatever is
    /// handling the decrypted exchange, not here.
    private var handshakeCompleted = false
    /// One report per connection: a failing handshake can raise several errors on
    /// its way down, and the host's `connections` count should say how many clients
    /// were refused, not how many errors BoringSSL emitted.
    private var reported = false

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event { handshakeCompleted = true }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        report(error)
        context.fireErrorCaught(error)
    }

    private func report(_ error: Error) {
        guard !handshakeCompleted, !reported else { return }
        guard Self.isHandshakeFailure(error) else { return }
        reported = true
        let detail = Self.describe(error)
        TunneledHostLog.shared.record(
            host: host, port: port, reason: .clientHandshakeFailed, detail: detail
        )
        Log.tls.error("""
        Client refused Loom's certificate for \(self.host, privacy: .public):\(self.port, privacy: .public) \
        — \(detail, privacy: .public). The host is pinned or Loom's CA is not in that client's \
        trust store; add it to the SSL scope's exclude list to let it through unread.
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

    /// The alert as BoringSSL named it, which is what separates "this host is
    /// pinned" from "your CA is not installed in this client".
    private static func describe(_ error: Error) -> String {
        guard case let .handshakeFailed(underlying)? = error as? NIOSSLError else {
            return String(describing: error)
        }
        return String(describing: underlying)
    }
}
