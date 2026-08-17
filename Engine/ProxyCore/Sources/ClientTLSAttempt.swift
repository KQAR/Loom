import Foundation
import LoomSharedModels
import NIOCore
import NIOTLS

/// What is known about one client-facing TLS handshake, shared by the two handlers
/// that watch it from opposite sides of `NIOSSLServerHandler`.
///
/// A class rather than a value because both handlers observe the *same* attempt and
/// each learns half of it: the one below the SSL handler sees raw inbound bytes and
/// the connection going away, the one above it sees NIOSSL's own events and errors.
/// Event-loop confined like the handlers themselves — see ProxyCore/CLAUDE.md
/// § Sendable escape hatches for what that forbids.
final class ClientTLSAttempt {
    /// The client sent at least one byte, i.e. it started a handshake. **This is the
    /// discriminator that makes reporting an abort safe**: without it, a client that
    /// opens a tunnel ahead of need and closes it unused — which browsers and pooled
    /// HTTP clients do constantly — looks exactly like one that refused Loom's leaf.
    var clientSpoke = false
    /// NIOSSL reported a completed handshake. After that a failure belongs to the
    /// exchange, not to the interception.
    var handshakeCompleted = false
    /// One report per connection, whichever side gets there first: a refusal can
    /// surface as an alert *and* as the connection closing, and the host's
    /// `connections` count should say how many clients were refused rather than how
    /// many events the refusal produced.
    var reported = false

    /// Record a failed interception in both places it has to appear — the aggregate
    /// the console reads, and a row in the request table.
    ///
    /// One function because the two are a pair, and the release where the row was
    /// missing is what this file exists to close: `TunneledHostLog` answers "which
    /// origins are unread" for the console and an agent, and neither is what the
    /// operator is looking at when a request produced nothing.
    func report(
        host: String, port: Int, code: FlowError.Code, detail: String, summary: String,
        client: Channel?, startedAt: Date, log: TunneledHostLog, store: FlowStore?
    ) {
        guard !reported else { return }
        reported = true
        log.recordClientFailure(host: host, port: port, code: code, detail: detail)
        guard let store else { return }
        TunnelFlow.recordFailure(
            host: host, port: port, startedAt: startedAt, client: client,
            reason: .clientHandshakeFailed,
            error: FlowError(summary, code: code, detail: detail),
            store: store
        )
    }
}

/// The half of the interception failure that raises **no error at all**.
///
/// `ClientTLSFailureReporter` sits above `NIOSSLServerHandler` and catches what
/// NIOSSL *reports* — a fatal alert becomes `NIOSSLError.handshakeFailed`, and a
/// refusing `curl` produces exactly that. A large class of real clients does not
/// send one: an Android app that pins a certificate typically closes the socket
/// after reading Loom's leaf, so BoringSSL sees a clean EOF, nothing is raised, and
/// the connection simply ends. From every surface Loom offers, the host then has no
/// flow, no tunnelled-host entry and no log line — while the operator has just
/// clicked Decrypt on it and is watching for the result.
///
/// That failure mode is specific to a whitelist scope and is the worst shape it has:
/// the one host somebody explicitly asked to read is the one that goes silent.
///
/// So this handler sits **below** the SSL handler, where the bytes are, and answers
/// the only question the reporter above cannot: did the client actually attempt a
/// handshake? An abandoned pre-connected tunnel — a browser or a pooled client
/// opening a `CONNECT` it never speaks on — sends nothing and is deliberately not
/// reported, which is the same rule `TunnelSniffHandler` applies to a tunnel that
/// stays silent past its deadline.
// @unchecked Sendable: event-loop confined, no lock — see ProxyCore/CLAUDE.md
// § Sendable escape hatches for what that forbids inside a `Task {}`.
final class ClientTLSAbortReporter: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let host: String
    private let port: Int
    private let attempt: ClientTLSAttempt
    private let log: TunneledHostLog
    private let store: FlowStore?
    private let startedAt = Date()

    init(
        host: String, port: Int, attempt: ClientTLSAttempt,
        log: TunneledHostLog = .shared, store: FlowStore? = nil
    ) {
        self.host = host
        self.port = port
        self.attempt = attempt
        self.log = log
        self.store = store
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Any inbound byte at this position is the client's — this handler is below
        // TLS, so the first one is the start of a ClientHello.
        attempt.clientSpoke = true
        context.fireChannelRead(data)
    }

    func channelInactive(context: ChannelHandlerContext) {
        report(client: context.channel)
        context.fireChannelInactive()
    }

    private func report(client: Channel?) {
        guard attempt.clientSpoke, !attempt.handshakeCompleted, !attempt.reported else { return }
        let detail = "the client closed the connection during the TLS handshake, without sending an alert"
        attempt.report(
            host: host, port: port, code: .clientHandshakeAborted, detail: detail,
            summary: "Client closed during the TLS handshake before sending an HTTP request",
            client: client, startedAt: startedAt, log: log, store: store
        )
        Log.tls.error("""
        Client abandoned the TLS handshake for \(self.host, privacy: .public):\(self.port, privacy: .public) \
        without an alert. The cause is unknown; Loom cannot infer pinning from a socket close.
        """)
    }
}
