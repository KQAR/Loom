import Foundation
import LoomSharedModels
import NIOCore
import NIOHTTP2

/// Terminates an intercepted HTTP/2 connection whose codec raised an error, and
/// records the fact.
///
/// Without it, a codec error travelled to the end of a pipeline that had nothing at
/// the tail and simply stopped existing. The connection stayed open, Loom sent no
/// GOAWAY and no RST_STREAM, and the client — which has no deadline of its own for
/// a request it has already written — waited forever. A phone showed a spinner that
/// never resolved while the capture insisted the request had never been made.
///
/// The measured trigger: `NIOHTTP2Errors.excessivelyLargeHeaderBlock`
/// (`HTTP2FrameParser`, on the HEADERS preflight and again while accumulating
/// CONTINUATION frames). SwiftNIO builds its frame decoder in `handlerAdded` with
/// HPACK's 16 KB default and only raises it when the peer **acknowledges** Loom's
/// SETTINGS (RFC 9113 §6.5.3), so a client whose first request on a fresh
/// connection carries a larger field section is rejected however large a value
/// Loom advertises. An app whose session cookies have grown past 16 KB does this on
/// every new connection.
///
/// Closing is not a choice here, it is the protocol: HPACK is stateful (RFC 7541
/// §2.3 — the dynamic table is shared across the whole connection), so a header
/// block that could not be decoded leaves the table desynchronised and every later
/// block on that connection undecodable. RFC 9113 §5.4.1 says a connection error is
/// signalled with GOAWAY and the connection closed; carrying on is not available.
///
/// **The rule this generalises: an error SwiftNIO raises is Loom's to answer.**
/// A pipeline with no error handler turns every codec failure into an infinite
/// wait, which is the single worst thing a debugging proxy can do — the operator
/// blames their app, and the capture agrees with them.
// @unchecked Sendable: event-loop confined, no lock — see ProxyCore/CLAUDE.md
// § Sendable escape hatches for what that forbids inside a `Task {}`.
final class HTTP2ConnectionErrorReporter: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame
    typealias InboundOut = HTTP2Frame

    private let host: String
    private let port: Int
    /// One record per connection, not per raised error.
    private var reported = false

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !reported {
            reported = true
            let detail = Self.describe(error)
            TunneledHostLog.shared.record(
                host: host, port: port, reason: .protocolError, detail: detail
            )
            Log.proxy.error("""
            HTTP/2 codec error on the intercepted connection to \
            \(self.host, privacy: .public):\(self.port, privacy: .public) — \(detail, privacy: .public). \
            Closing: HPACK state is per-connection, so nothing after an undecodable header block \
            can be read. The client sees a closed connection instead of waiting forever.
            """)
        }
        context.fireErrorCaught(error)
        // `close` rather than a bare fireErrorCaught: NIOHTTP2Handler emits GOAWAY
        // for the errors it raises itself, and for anything it doesn't, a closed
        // connection is still an answer where silence is not.
        context.close(promise: nil)
    }

    /// Name the error the way `NIOHTTP2Errors` does — `excessivelyLargeHeaderBlock`
    /// is the difference between "your client sent too much" and "Loom broke".
    private static func describe(_ error: Error) -> String {
        String(describing: type(of: error)) + ": " + String(describing: error)
    }
}
