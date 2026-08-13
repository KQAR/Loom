import Foundation
import Synchronization
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHTTPCompression
import NIOSSL
import LoomSharedModels

/// Upstream client built directly on SwiftNIO (M4), replacing an earlier URLSession-based forwarder.
/// Unlike URLSession it lets Loom own every request header — notably `Host`, so a
/// map-remote rule can keep the original Host (`keepHostHeader`) — and originates
/// its own normally-validated TLS to the real server for the intercept path.
///
/// This is the foundation increment: it still returns a buffered `ForwardResult`
/// (whole body collected) and decompresses like the old path so captures stay
/// readable. True chunk-at-a-time streaming (SSE / large bodies), WebSocket, and
/// HTTP/2 build on this same NIO client in later increments.
// @unchecked Sendable with nothing to protect: every stored property is a `let`.
// The hatch exists because `EventLoopGroup` carries no Sendable conformance.
final class NIOStreamingForwarder: UpstreamForwarding, @unchecked Sendable {
    /// Largest decompressed:compressed ratio accepted from an upstream response.
    /// See the decompressor's installation below for why this isn't `.none`.
    static let maxDecompressionRatio = 100

    private let group: EventLoopGroup
    private let connectTimeout: TimeAmount
    /// Mutual-TLS identities, consulted per upstream host. Nil = never present a
    /// client certificate (the default, and what an embedder gets unless it wires
    /// one — presenting a credential is not a neutral default).
    private let clientIdentities: ClientIdentityProviding?
    /// Keeps upstream connections alive between requests. See
    /// `UpstreamConnectionPool` for what a missing one used to cost.
    private let pool: UpstreamConnectionPool

    init(
        group: EventLoopGroup,
        connectTimeout: TimeAmount = .seconds(30),
        clientIdentities: ClientIdentityProviding? = nil,
        pool: UpstreamConnectionPool = UpstreamConnectionPool()
    ) {
        self.group = group
        self.connectTimeout = connectTimeout
        self.clientIdentities = clientIdentities
        self.pool = pool
    }

    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        try await forwardStream(method: method, url: url, headers: headers, body: .bytes(body)).collect()
    }

    func forwardStream(method: String, url: URL, headers: [HeaderPair], body: RequestBody) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let host = url.host else {
                continuation.finish(throwing: ForwarderError.invalidURL(url.absoluteString))
                return
            }
            let isTLS = (url.scheme?.lowercased() == "https")
            let port = url.port ?? (isTLS ? 443 : 80)

            // Resolved before the attempt so it is available on the failure path too:
            // an mTLS handshake failure is the case where naming the identity (or its
            // absence) is the whole diagnosis. See `UpstreamTLSError`.
            let identity = isTLS ? self.clientIdentities?.identityLabel(forHost: host) : nil

            // The *context* is resolved here, before the attempt, and the handler is
            // built from it inside the channel initializer below. That split is not
            // cosmetic: resolving the context is the step that fails for a configured
            // identity that won't load, and that failure has to reach the caller
            // verbatim (naming the identity, not the origin — see the type note on
            // `resolveClientTLS`). `NIOSSLContext` is `Sendable`; `NIOSSLClientHandler`
            // is not, which is why only the latter moves inside.
            let clientTLS: (context: NIOSSLContext, serverName: String?)?
            do {
                clientTLS = try isTLS ? self.resolveClientTLS(host: host) : nil
            } catch {
                // A configured identity that won't load: the error already names it
                // (the store validates on the way in), so it is passed through as-is
                // rather than wrapped in a handshake story that never happened.
                continuation.finish(throwing: error)
                return
            }

            let key = UpstreamPoolKey(host: host, port: port, isTLS: isTLS, identity: identity)
            let active = ActiveUpstreamBox()
            let task = Task {
                do {
                    try await self.runExchange(
                        key: key, clientTLS: clientTLS, method: method, url: url,
                        headers: headers, body: body, continuation: continuation, active: active
                    )
                    // The forwarder, not the relay, terminates the caller's stream:
                    // a failure with nothing yet yielded is a retry candidate, and a
                    // relay that had already finished the stream would have spent
                    // the outcome that decision needs.
                    continuation.yield(.end)
                    continuation.finish()
                } catch {
                    // Two wrappers, one hop each, and neither touches what the other
                    // claims: the TLS one only wraps NIOSSL's own errors, the
                    // connection one only wraps a failure to reach the address at all.
                    // Anything else — a mid-exchange close, an invalid URL — passes
                    // through both untouched.
                    let contextualized = UpstreamTLSError.wrapping(
                        error, host: host, isTLS: isTLS, identity: identity
                    )
                    continuation.finish(throwing: UpstreamConnectionError.wrapping(
                        contextualized, host: host, port: port
                    ))
                }
            }
            // On stream completion/cancellation, stop connecting and close the socket.
            continuation.onTermination = { _ in task.cancel(); active.terminate() }
        }
    }

    // MARK: - One exchange, over a pooled or a fresh connection

    /// Run one request/response, preferring a pooled connection.
    ///
    /// The retry is the load-bearing part of pooling and not a nicety: a parked
    /// connection can be closed by the origin at any moment, and the FIN can land
    /// in the window between leasing it and writing to it. Without a retry, pooling
    /// would trade a reliable 96 ms for an occasional failed request — a bad trade
    /// at any latency.
    ///
    /// It is offered only for a request whose body is `.bytes`, which is the whole
    /// reason `RequestBody` is a sum type here. A `.stream` body is a live,
    /// back-pressured pull from the client that is consumed exactly once; there is
    /// no second copy to re-send, so a streamed request opens its own connection
    /// rather than gamble one. It still *releases* into the pool afterwards, so the
    /// requests that follow it reuse the socket it opened.
    private func runExchange(
        key: UpstreamPoolKey,
        clientTLS: (context: NIOSSLContext, serverName: String?)?,
        method: String, url: URL, headers: [HeaderPair], body: RequestBody,
        continuation: AsyncThrowingStream<UpstreamResponseEvent, Error>.Continuation,
        active: ActiveUpstreamBox
    ) async throws {
        let replayable: Bool
        if case .bytes = body { replayable = true } else { replayable = false }

        if replayable, let pooled = pool.lease(key) {
            do {
                try await attempt(
                    on: pooled, method: method, url: url, headers: headers, body: body,
                    continuation: continuation, active: active
                )
                return
            } catch let failure as UpstreamAttemptFailure {
                guard !failure.didYield else { throw failure.underlying }
                // Bytes-in-hand makes the request *re-sendable*; it does not make
                // it *re-executable*. RFC 9110 §9.2.2: an automatic retry is only
                // allowed for an idempotent method, or when the request provably
                // never reached the origin — here, when its final flush failed,
                // so the origin cannot have read a complete request. A POST that
                // was fully written and then went dark may have been acted on,
                // and running it twice is the caller's decision, never the pool's.
                guard Self.isIdempotent(method) || !failure.requestWritten else {
                    throw failure.underlying
                }
                Log.forward.debug(
                    """
                    Pooled upstream connection to \(key.host, privacy: .public):\(key.port, privacy: .public) \
                    was stale; retrying on a fresh one
                    """
                )
            }
        }

        let fresh = try await connect(key: key, clientTLS: clientTLS)
        do {
            try await attempt(
                on: fresh, method: method, url: url, headers: headers, body: body,
                continuation: continuation, active: active
            )
        } catch let failure as UpstreamAttemptFailure {
            throw failure.underlying
        }
    }

    /// Arm the connection's slot, write the request, await the response's end, and
    /// then either park the connection or close it.
    private func attempt(
        on connection: UpstreamConnection,
        method: String, url: URL, headers: [HeaderPair], body: RequestBody,
        continuation: AsyncThrowingStream<UpstreamResponseEvent, Error>.Continuation,
        active: ActiveUpstreamBox
    ) async throws {
        guard active.adopt(connection) else {
            // The consumer already went away; nothing to run this exchange for.
            connection.close()
            throw CancellationError()
        }

        let promise = connection.channel.eventLoop.makePromise(of: UpstreamAttemptEnd.self)
        connection.slot.arm(
            continuation: continuation,
            methodIsHead: method.uppercased() == "HEAD"
        ) { result in
            promise.completeWith(result.mapError { $0 as Error })
        }

        // A TLS handshake failure does not come back from `connect()` — the TCP
        // connection succeeds and the handshake fails later, inside the pipeline —
        // so on a fresh connection it can land before the slot is armed. The slot
        // *holds* such a failure and `arm` above has already replayed it, with
        // NIOSSL's own error intact for `UpstreamTLSError` to name. This check is
        // the backstop for a channel that died before the slot ever heard why.
        if !connection.channel.isActive {
            connection.slot.fail(ForwarderError.connectionClosed)
        }

        // Whether the request's final flush succeeded — the fact the retry
        // decision (RFC 9110 §9.2.2) and the release decision below both need.
        var requestWritten = false
        do {
            try await Self.writeRequest(
                channel: connection.channel, method: method, url: url,
                host: connection.key.host, port: connection.key.port, headers: headers, body: body
            )
            requestWritten = true
        } catch {
            // Disarms and completes the promise; a no-op if the relay already saw
            // the failure first, which is the ordinary race on a dead socket.
            connection.slot.fail(error)
        }

        let end: UpstreamAttemptEnd
        do {
            end = try await promise.futureResult.get()
        } catch let failure as UpstreamAttemptFailure {
            active.clear()
            connection.close()
            // Re-stamp with the measured write outcome: the slot fills this field
            // conservatively because it never sees the write side.
            throw UpstreamAttemptFailure(
                underlying: failure.underlying, didYield: failure.didYield,
                requestWritten: requestWritten
            )
        } catch {
            active.clear()
            connection.close()
            throw error
        }

        active.clear()
        switch end {
        case .reusable where requestWritten:
            pool.release(connection)
        case .reusable:
            // The response completed but this request's body never fully left —
            // a server that answered early (413, an auth refusal) while the
            // upload still had bytes owing. The response is fine to deliver; the
            // connection is mid-request from the origin's point of view, and a
            // next request written onto it would land inside the unfinished body.
            connection.close()
        case .mustClose:
            connection.close()
        }
    }

    /// Open a new upstream connection with the response relay already installed.
    private func connect(
        key: UpstreamPoolKey, clientTLS: (context: NIOSSLContext, serverName: String?)?
    ) async throws -> UpstreamConnection {
        let slot = UpstreamExchangeSlot()
        let notifier = UpstreamInactiveNotifier()
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(connectTimeout)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    if let clientTLS {
                        try sync.addHandler(NIOSSLClientHandler(
                            context: clientTLS.context, serverHostname: clientTLS.serverName
                        ))
                    }
                    try sync.addHTTPClientHandlers()
                    // Decompress gzip/deflate so relayed/captured bytes are plaintext;
                    // the now-wrong Content-Encoding/Length are stripped on `.head`.
                    // The ratio cap is a decompression-bomb guard: bodies come from
                    // arbitrary origins, and `.none` is the setting swift-nio-extras
                    // itself documents as leaving you open to denial of service. 100x
                    // is far above real content (text gzips ~3-10x) and far below a
                    // zip bomb (1000x+), so it costs nothing legitimate. The capture
                    // is separately capped; this bounds the *inflation*.
                    //
                    // Safe to keep across a pooled connection's later requests: it
                    // builds a decoder per response `.head` and drops it on `.end`.
                    try sync.addHandler(
                        NIOHTTPResponseDecompressor(limit: .ratio(Self.maxDecompressionRatio))
                    )
                    try sync.addHandler(UpstreamResponseRelay(slot: slot, notifier: notifier))
                }
            }
        let channel = try await bootstrap.connect(host: key.host, port: key.port).get()
        let connection = UpstreamConnection(key: key, channel: channel, slot: slot)
        // Weak: while the connection is parked the pool holds it, and once it is
        // neither parked nor in flight there is nothing left to evict.
        notifier.onInactive { [pool, weak connection] in
            guard let connection else { return }
            pool.forget(connection)
        }
        return connection
    }

    // MARK: - Request

    private static func writeRequest(
        channel: Channel, method: String, url: URL, host: String, port: Int,
        headers: [HeaderPair], body: RequestBody
    ) async throws {
        var httpHeaders = HTTPHeaders()
        var sawHost = false
        for header in headers {
            let lower = header.name.lowercased()
            // We set the framing (Content-Length / Transfer-Encoding) ourselves; drop
            // hop-by-hop and any framing the client stack must own. Host is kept if
            // present (so keepHostHeader works).
            if HTTPUtil.isHopByHop(lower) || lower == "content-length" || lower == "transfer-encoding" { continue }
            if lower == "host" { sawHost = true }
            httpHeaders.add(name: header.name, value: header.value)
        }
        if !sawHost {
            let defaultPort = url.scheme?.lowercased() == "https" ? 443 : 80
            httpHeaders.add(name: "Host", value: port == defaultPort ? host : "\(host):\(port)")
        }

        // Pin Accept-Encoding to what the response pipeline can actually inflate.
        // NIOHTTPResponseDecompressor only handles gzip/deflate, but the client's
        // own list (every browser advertises `br`, Chrome also `zstd`) would be
        // forwarded verbatim — the origin then responds with an encoding we pass
        // through still-compressed while sanitizeDecodedResponseHeaders strips the
        // Content-Encoding the client would need to decode it. Compressed bytes
        // typed as plaintext: broken for the client, unreadable in the capture.
        httpHeaders.replaceOrAdd(name: "Accept-Encoding", value: "gzip, deflate")

        // Frame the body: a known length (buffered body, or a streamed body whose
        // client sent Content-Length) uses Content-Length; an unknown-length stream
        // (client used chunked) re-frames as chunked upstream.
        let knownLength: Int?
        switch body {
        case let .bytes(data): knownLength = data?.count ?? 0
        case let .stream(_, contentLength): knownLength = contentLength
        }
        if let knownLength {
            httpHeaders.replaceOrAdd(name: "Content-Length", value: String(knownLength))
        } else {
            httpHeaders.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
        }

        let head = HTTPRequestHead(
            version: .http1_1, method: httpMethod(method), uri: requestURI(url), headers: httpHeaders
        )
        channel.write(HTTPClientRequestPart.head(head), promise: nil)

        switch body {
        case let .bytes(data):
            if let data, !data.isEmpty {
                var buffer = channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
            }
        case let .stream(chunks, _):
            // Await each flush so a slow upstream back-pressures the pull from the
            // client stream (which is itself back-pressured to the client socket) —
            // in-flight bytes stay bounded end to end.
            for try await chunk in chunks where !chunk.isEmpty {
                var buffer = channel.allocator.buffer(capacity: chunk.count)
                buffer.writeBytes(chunk)
                try await channel.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(buffer))).get()
            }
        }
        // Awaited, unlike the parts above: on a pooled connection the origin may
        // have closed while it was parked, and this flush is where that surfaces.
        // With `promise: nil` the failure was swallowed and the exchange waited on
        // a response the socket could never carry.
        try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
    }

    /// Origin-form request target: path + query (path defaults to "/").
    private static func requestURI(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.path.isEmpty ? "/" : url.path
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { return "\(path)?\(query)" }
        return path
    }

    /// RFC 9110 §9.2.2's idempotent set. PUT and DELETE are in it by definition —
    /// repeating them re-asserts the same state — and POST/PATCH are out, which is
    /// the half that matters: those are the requests a retry can execute twice.
    static func isIdempotent(_ method: String) -> Bool {
        switch method.uppercased() {
        case "GET", "HEAD", "PUT", "DELETE", "OPTIONS", "TRACE": return true
        default: return false
        }
    }

    private static func httpMethod(_ raw: String) -> HTTPMethod {
        switch raw.uppercased() {
        case "GET": return .GET
        case "POST": return .POST
        case "PUT": return .PUT
        case "DELETE": return .DELETE
        case "PATCH": return .PATCH
        case "HEAD": return .HEAD
        case "OPTIONS": return .OPTIONS
        case "TRACE": return .TRACE
        case "CONNECT": return .CONNECT
        default: return .RAW(value: raw.uppercased())
        }
    }

    /// The upstream TLS handler for `host`: normally the one shared, trust-store-only
    /// context, but a context carrying a client certificate when an mTLS identity is
    /// configured for this host. A configured-but-unloadable identity **throws**
    /// rather than falling back to the shared context: silently connecting without
    /// the credential would fail the handshake anyway, and the error would name the
    /// origin instead of the identity the operator can fix.
    /// The two `Sendable` ingredients an upstream TLS handler is built from, resolved
    /// **before** the connection attempt.
    ///
    /// Everything that can fail for a *configuration* reason fails here: a configured
    /// identity whose bundle won't load throws out of `context(forHost:)`, and the
    /// caller passes that error through untouched, because it already names the
    /// identity — which is the thing an operator can fix. Building the handler is left
    /// to the channel initializer, where the connection actually happens.
    private func resolveClientTLS(host: String) throws -> (context: NIOSSLContext, serverName: String?) {
        // IP-literal peers can't take an SNI/validation hostname.
        let serverName = SharedTLS.isIPLiteral(host) ? nil : host
        // Identity for this host → its context; otherwise the provider's own
        // no-identity context (same trust settings, no client certificate), and only
        // then the process-wide default. The middle step keeps both paths on one
        // trust configuration; see `ClientIdentityProviding.baseContext()`.
        let context = try clientIdentities?.context(forHost: host)
            ?? clientIdentities?.baseContext()
            ?? SharedTLS.clientContext
        return (context, serverName)
    }
}

enum ForwarderError: Error {
    case invalidURL(String)
    case connectionClosed
}

/// Tracks the connection an in-flight exchange is running on, so the stream's
/// `onTermination` can close it when the consumer walks away mid-response — and,
/// just as importantly, so it does **not** close one that has already been handed
/// back to the pool.
private final class ActiveUpstreamBox: Sendable {
    private struct State {
        var connection: UpstreamConnection?
        var terminated = false
    }

    private let state = Mutex(State())

    /// Take ownership of `connection` for the duration of an exchange. Returns
    /// false if the consumer already terminated, in which case there is nothing
    /// left to run and the caller closes it.
    func adopt(_ connection: UpstreamConnection) -> Bool {
        state.withLock { state in
            guard !state.terminated else { return false }
            state.connection = connection
            return true
        }
    }

    /// The exchange finished; whatever happens to the connection now is the pool's
    /// decision, not this box's.
    func clear() {
        state.withLock { $0.connection = nil }
    }

    func terminate() {
        let connection = state.withLock { state -> UpstreamConnection? in
            state.terminated = true
            let current = state.connection
            state.connection = nil
            return current
        }
        connection?.close()
    }
}

/// Relays one HTTP response upstream→stream as it arrives: `.head` then each body
/// chunk, so SSE / long-poll / large downloads flow through instead of being
/// buffered.
///
/// Two things it deliberately does **not** do, both of which it used to. It does not
/// close the channel on `.end` — that is what made every request pay a fresh TCP
/// and TLS handshake, and the decision now belongs to the pool. And it does not
/// terminate the caller's stream: it hands the outcome to `UpstreamExchangeSlot`
/// and the forwarder decides, because a failure with nothing yielded is retryable
/// and finishing the stream here would spend that choice.
///
/// Plainly `Sendable`, not `@unchecked`: it holds no mutable state at all. What
/// would have been per-exchange handler state lives in the slot, which is exactly
/// what lets one relay serve many exchanges on a pooled connection.
private final class UpstreamResponseRelay: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let slot: UpstreamExchangeSlot
    private let notifier: UpstreamInactiveNotifier

    init(slot: UpstreamExchangeSlot, notifier: UpstreamInactiveNotifier) {
        self.slot = slot
        self.notifier = notifier
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            // Body is decompressed by the decompressor, so Content-Encoding/Length
            // no longer describe the bytes — strip them (the client writer re-frames).
            let headers = HTTPUtil.sanitizeDecodedResponseHeaders(HTTPUtil.headerPairs(head.headers))
            let version = "HTTP/\(head.version.major).\(head.version.minor)"
            slot.receivedHead(head, headers: headers, httpVersion: version)
        case var .body(chunk):
            if let bytes = chunk.readBytes(length: chunk.readableBytes) {
                slot.receivedBody(Data(bytes))
            }
        case .end:
            slot.completeSuccessfully()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Fails an armed slot; a no-op when nothing is armed, which is what a
        // connection dying while parked in the pool looks like. Either way the pool
        // must stop offering it.
        slot.fail(ForwarderError.connectionClosed)
        notifier.fire()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        slot.fail(error)
        context.close(promise: nil)
    }
}
