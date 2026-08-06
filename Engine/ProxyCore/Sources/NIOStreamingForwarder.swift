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

    init(
        group: EventLoopGroup,
        connectTimeout: TimeAmount = .seconds(30),
        clientIdentities: ClientIdentityProviding? = nil
    ) {
        self.group = group
        self.connectTimeout = connectTimeout
        self.clientIdentities = clientIdentities
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

            let group = self.group
            let connectTimeout = self.connectTimeout
            let box = ChannelBox()
            let task = Task {
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
                            try sync.addHandler(
                                NIOHTTPResponseDecompressor(limit: .ratio(Self.maxDecompressionRatio))
                            )
                            try sync.addHandler(StreamingResponseHandler(
                                continuation: continuation,
                                contextualize: { UpstreamTLSError.wrapping($0, host: host, isTLS: isTLS, identity: identity) }
                            ))
                        }
                    }
                do {
                    let channel = try await bootstrap.connect(host: host, port: port).get()
                    box.set(channel)
                    try await Self.writeRequest(channel: channel, method: method, url: url, host: host, port: port, headers: headers, body: body)
                } catch {
                    continuation.finish(throwing: UpstreamTLSError.wrapping(
                        error, host: host, isTLS: isTLS, identity: identity
                    ))
                }
            }
            // On stream completion/cancellation, stop connecting and close the socket.
            continuation.onTermination = { _ in task.cancel(); box.close() }
        }
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
        channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
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

/// Thread-safe holder so the stream's onTermination can close the upstream channel
/// once it's connected (connect happens asynchronously inside a Task).
private final class ChannelBox: Sendable {
    /// `Channel` is not `Sendable`; holding it inside the `Mutex` is what makes this
    /// box safe without an `@unchecked` on the class.
    private struct State {
        var channel: Channel?
        var closed = false
    }

    private let state = Mutex(State())

    func set(_ channel: Channel) {
        state.withLock { state in
            if state.closed { channel.close(promise: nil) } else { state.channel = channel }
        }
    }

    func close() {
        state.withLock { state in
            state.closed = true
            state.channel?.close(promise: nil)
            state.channel = nil
        }
    }
}

/// Relays one HTTP response upstream→stream as it arrives: `.head` then each body
/// chunk then `.end`, so SSE / long-poll / large downloads flow through instead of
/// being buffered. Closes the upstream channel when the response ends.
// @unchecked Sendable: event-loop confined, no lock — see ProxyCore/CLAUDE.md
// § Sendable escape hatches for what that forbids inside a `Task {}`.
private final class StreamingResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let continuation: AsyncThrowingStream<UpstreamResponseEvent, Error>.Continuation
    /// Adds context to a failing error on its way out. A TLS handshake failure does
    /// **not** come back from `connect()` — the TCP connection succeeds and the
    /// handshake fails afterwards, inside the pipeline, arriving here as
    /// `errorCaught`. So this is the only place that sees it, and wrapping it at the
    /// call site (as this first tried) silently misses every one.
    private let contextualize: @Sendable (Error) -> Error
    private var finished = false

    init(
        continuation: AsyncThrowingStream<UpstreamResponseEvent, Error>.Continuation,
        contextualize: @escaping @Sendable (Error) -> Error = { $0 }
    ) {
        self.continuation = continuation
        self.contextualize = contextualize
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            // Body is decompressed by the decompressor, so Content-Encoding/Length
            // no longer describe the bytes — strip them (the client writer re-frames).
            let headers = HTTPUtil.sanitizeDecodedResponseHeaders(HTTPUtil.headerPairs(head.headers))
            let version = "HTTP/\(head.version.major).\(head.version.minor)"
            continuation.yield(.head(statusCode: Int(head.status.code), httpVersion: version, headers: headers))
        case var .body(chunk):
            if let bytes = chunk.readBytes(length: chunk.readableBytes) {
                continuation.yield(.body(Data(bytes)))
            }
        case .end:
            finish(nil)
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(ForwarderError.connectionClosed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(error)
        context.close(promise: nil)
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        if let error {
            continuation.finish(throwing: contextualize(error))
        } else {
            continuation.yield(.end)
            continuation.finish()
        }
    }
}
