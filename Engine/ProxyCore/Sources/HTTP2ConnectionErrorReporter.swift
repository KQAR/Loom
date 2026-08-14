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
    /// Whether any **stream** frame has reached this handler, i.e. whether the
    /// connection ever carried a request. The discriminator for the downgrade below: a
    /// codec error before the first one is the pre-ACK HPACK limit
    /// (`HTTP2DowngradeRegistry`), and one after it is something else that must not
    /// quietly change how the next connection is negotiated.
    ///
    /// **Stream frames only, and that distinction is the whole predicate.** Counting
    /// *any* frame was the first version and it never fired: a client sends its
    /// SETTINGS in the same write as its first HEADERS (RFC 9113 §3.4), that SETTINGS
    /// reaches this handler, and the connection then looks like one that had already
    /// worked. Connection-level frames — SETTINGS, PING, GOAWAY, a stream-0
    /// WINDOW_UPDATE — are housekeeping and say nothing about whether a request
    /// survived.
    private var deliveredAStreamFrame = false
    /// Where a downgrade decision is recorded, and the CA whose cached context has to
    /// be dropped for it to take effect on the next connection.
    private let downgrades: HTTP2DowngradeRegistry
    private let certificateAuthority: CertificateAuthority?
    /// The HTTP/2 error code NIOHTTP2 put in the GOAWAY it sent, if it sent one.
    ///
    /// **The code is the whole diagnosis and the error type does not carry it.**
    /// `frameDecoder.nextFrame()` throws `InternalError.codecError(code:)` from about
    /// forty places, and `NIOHTTP2Handler` turns every one of them into the same
    /// `NIOHTTP2Errors.unableToParseFrame()` — the code goes into the GOAWAY frame
    /// and nowhere else. So a report without it says "Loom's codec refused this
    /// connection" and cannot distinguish an HPACK dynamic-table desync
    /// (`compressionError`) from a frame larger than the advertised maximum
    /// (`frameSizeError`) from an illegal frame on stream 0 (`protocolError`) —
    /// three different bugs with three different owners.
    ///
    /// Filled in by `HTTP2GoAwayObserver`, which sits head-side of the codec — the
    /// only position from which that frame is visible. This handler is at the tail,
    /// where `NIOHTTP2Handler`'s own outbound writes never arrive.
    private let goAway: HTTP2GoAwayCode

    init(
        host: String, port: Int, log: TunneledHostLog = .shared,
        store: FlowStore? = nil, goAway: HTTP2GoAwayCode = HTTP2GoAwayCode(),
        downgrades: HTTP2DowngradeRegistry = .shared,
        certificateAuthority: CertificateAuthority? = nil
    ) {
        self.downgrades = downgrades
        self.certificateAuthority = certificateAuthority
        self.host = host
        self.port = port
        self.log = log
        self.store = store
        self.goAway = goAway
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if Self.unwrapInboundIn(data).streamID != .rootStream { deliveredAStreamFrame = true }
        context.fireChannelRead(data)
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
                let detail = Self.describe(error, goAwayCode: goAway.code)
                downgradeIfHPACKRefusedTheFirstHeaderBlock(error)
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

    /// Stop offering h2 to this host, for this session.
    ///
    /// **Three conditions, and each one narrows a way this could fire wrongly.** The
    /// error must be the pre-ACK HPACK limit — a GOAWAY `compressionError` (how
    /// NIOHTTP2 reports `MaxHeaderListSizeViolation` after wrapping it as
    /// `unableToParseFrame()`) **or** `ExcessivelyLargeHeaderBlock` itself, which
    /// the decoder raises before that wrap and which never carries a GOAWAY code.
    /// A frame-size or protocol violation is the client's bug and hiding it behind
    /// a downgrade would be Loom lying about whose fault it is. No *stream* frame
    /// may have been delivered, so this is the connection's first header block,
    /// which is the only moment the pre-ACK limit applies (see
    /// `deliveredAStreamFrame` — counting connection-level frames too made this
    /// never fire). And it runs once: `downgrade` reports whether it changed
    /// anything, and only then is the cached TLS context dropped, because that
    /// context is what still advertises `h2`.
    ///
    /// What it costs is stated rather than hidden: the app now speaks HTTP/1.1 to Loom,
    /// so it loses multiplexing and every flow on that host records `HTTP/1.1` as the
    /// client protocol. That is true of what happened and false about what the client
    /// would have done without Loom in the path, which is why the flows carry
    /// `FlowTransport.clientProtocolDowngraded` and the log says so here.
    private func downgradeIfHPACKRefusedTheFirstHeaderBlock(_ error: Error) {
        guard !deliveredAStreamFrame else { return }
        let isHPACKLimit = goAway.code == .compressionError
            || error is NIOHTTP2Errors.ExcessivelyLargeHeaderBlock
        guard isHPACKLimit else { return }
        guard downgrades.downgrade(host: host) else { return }
        certificateAuthority?.invalidateContext(for: host)
        Log.tls.error("""
        Serving \(self.host, privacy: .public) as HTTP/1.1 from now on: Loom's HTTP/2 decoder         refused the first header block with COMPRESSION_ERROR, which is SwiftNIO's 16 KB HPACK         limit applying before the client ACKs Loom's SETTINGS (RFC 9113 §3.4 lets it send first).         The exchange is still decrypted and captured; the client leg is no longer the protocol         the app would have used, and every flow says so.
        """)
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
    /// is the difference between "your client sent too much" and "Loom broke" — and
    /// append the GOAWAY code when there is one, because for `unableToParseFrame`
    /// the type says nothing and the code says everything (see `goAwayCode`).
    static func describe(_ error: Error, goAwayCode: HTTP2ErrorCode? = nil) -> String {
        var detail = String(describing: type(of: error)) + ": " + String(describing: error)
        if let goAwayCode { detail += " [GOAWAY \(goAwayCode)]" }
        return detail
    }
}
