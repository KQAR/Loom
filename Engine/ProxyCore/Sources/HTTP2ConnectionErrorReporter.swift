import Foundation
import LoomSharedModels
import NIOCore
import NIOHTTP2
import NIOSSL

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
/// **Not every error reaching this handler is that error**, and the first version
/// treated them all alike — which put ordinary connection teardown on the one
/// surface an operator reads to find out why a host is broken. Measured on a real
/// device within a day of shipping: the app's main API host — 27 requests, all
/// captured, all 200 — listed as `protocolError` with "Connection reset by peer",
/// because a phone tearing down an idle connection with RST instead of close_notify
/// is normal mobile behaviour, not a codec failure. Three tiers now:
///
/// - **Stream-scoped** (`NIOHTTP2Errors.StreamError`): NIOHTTP2 already answered
///   with RST_STREAM and the connection — HPACK table included — is intact
///   (RFC 9113 §5.4.2). Closing here would kill every other in-flight stream on
///   the connection for one stream's failure. Pass through, nothing recorded.
/// - **Transport teardown** (`NIOSSLError` / BoringSSL / `IOError` /
///   `ChannelError`): the TLS or TCP layer underneath is gone or going — an
///   unclean shutdown, a reset, a write on a closed channel. Close (idempotent,
///   and an answer is still owed if anything is left waiting) but record nothing:
///   the traffic on this connection was captured fine, and a handshake that
///   *failed* is `ClientTLSFailureReporter`'s to report.
/// - **Everything else** — the connection-level codec errors this handler exists
///   for — record `.protocolError` + close, as before. This tier is deliberately
///   the default: an unrecognised error type gets the close-and-say-so treatment,
///   never the silent open connection, because a wrongly-killed connection is
///   retried by the client and a wrongly-kept one hangs forever.
// @unchecked Sendable: event-loop confined, no lock — see ProxyCore/CLAUDE.md
// § Sendable escape hatches for what that forbids inside a `Task {}`.
final class HTTP2ConnectionErrorReporter: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame
    typealias InboundOut = HTTP2Frame

    private let host: String
    private let port: Int
    private let log: TunneledHostLog
    /// Where the failed connection is recorded as a flow. Optional so the reporter
    /// can be exercised on its own — every production path supplies one.
    private let store: FlowStore?
    /// When the connection reached this handler, so the row carries a duration.
    private let startedAt = Date()
    /// One record per connection, not per raised error.
    private var reported = false

    init(host: String, port: Int, log: TunneledHostLog = .shared, store: FlowStore? = nil) {
        self.host = host
        self.port = port
        self.log = log
        self.store = store
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        switch Self.classify(error) {
        case .streamScoped:
            // RST_STREAM already went out and the connection is still usable.
            Log.proxy.debug("""
            HTTP/2 stream error on the intercepted connection to \
            \(self.host, privacy: .public):\(self.port, privacy: .public) — \
            \(Self.describe(error), privacy: .public). RST_STREAM answered it; the connection stays up.
            """)
            context.fireErrorCaught(error)

        case .transportTeardown:
            context.fireErrorCaught(error)
            context.close(promise: nil)

        case .connectionFatal:
            if !reported {
                reported = true
                let detail = Self.describe(error)
                log.record(host: host, port: port, reason: .protocolError, detail: detail)
                // And as a row, for the same reason `ClientTLSFailureReporter`
                // records one: the console holds the aggregate, the request table is
                // where the operator is looking when a request produced nothing.
                if let store {
                    TunnelFlow.recordFailure(
                        host: host, port: port, startedAt: startedAt, client: context.channel,
                        error: "Loom could not read the HTTP/2 connection — \(detail)", store: store
                    )
                }
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
    }

    enum Verdict: Equatable {
        case streamScoped
        case transportTeardown
        case connectionFatal
    }

    /// Which of the three answers this error deserves.
    ///
    /// The stream tier matches only NIOHTTP2's explicit wrapper. The state machine
    /// also fires a handful of *bare* errors (`badStreamStateTransition`) for
    /// stream-scoped failures; those land in the fatal tier and close the
    /// connection — stricter than RFC 9113 §5.4.2 requires, accepted deliberately,
    /// because enumerating them would track NIOHTTP2's internals version by
    /// version and the failure mode of a miss here (silent hang) is the very bug
    /// this handler was written for. A client whose connection is over-closed
    /// retries; one left waiting does not.
    static func classify(_ error: Error) -> Verdict {
        if error is NIOHTTP2Errors.StreamError { return .streamScoped }
        if error is NIOSSLError || error is BoringSSLError { return .transportTeardown }
        if error is IOError || error is ChannelError { return .transportTeardown }
        return .connectionFatal
    }

    /// Name the error the way `NIOHTTP2Errors` does — `excessivelyLargeHeaderBlock`
    /// is the difference between "your client sent too much" and "Loom broke".
    private static func describe(_ error: Error) -> String {
        String(describing: type(of: error)) + ": " + String(describing: error)
    }
}
