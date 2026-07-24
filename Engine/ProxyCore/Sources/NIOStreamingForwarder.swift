import Foundation
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
final class NIOStreamingForwarder: UpstreamForwarding, @unchecked Sendable {
    private let group: EventLoopGroup
    private let connectTimeout: TimeAmount

    init(group: EventLoopGroup, connectTimeout: TimeAmount = .seconds(30)) {
        self.group = group
        self.connectTimeout = connectTimeout
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

            let sslHandler: NIOSSLClientHandler?
            do {
                sslHandler = try isTLS ? Self.makeSSLHandler(host: host) : nil
            } catch {
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
                        let tlsFuture: EventLoopFuture<Void> = sslHandler.map {
                            channel.pipeline.addHandler($0)
                        } ?? channel.eventLoop.makeSucceededVoidFuture()
                        return tlsFuture
                            .flatMap { channel.pipeline.addHTTPClientHandlers() }
                            // Decompress gzip/deflate so relayed/captured bytes are plaintext;
                            // the now-wrong Content-Encoding/Length are stripped on `.head`.
                            .flatMap { channel.pipeline.addHandler(NIOHTTPResponseDecompressor(limit: .none)) }
                            .flatMap { channel.pipeline.addHandler(StreamingResponseHandler(continuation: continuation)) }
                    }
                do {
                    let channel = try await bootstrap.connect(host: host, port: port).get()
                    box.set(channel)
                    try await Self.writeRequest(channel: channel, method: method, url: url, host: host, port: port, headers: headers, body: body)
                } catch {
                    continuation.finish(throwing: error)
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
        channel.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)

        switch body {
        case let .bytes(data):
            if let data, !data.isEmpty {
                var buffer = channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                channel.write(NIOAny(HTTPClientRequestPart.body(.byteBuffer(buffer))), promise: nil)
            }
        case let .stream(chunks, _):
            // Await each flush so a slow upstream back-pressures the pull from the
            // client stream (which is itself back-pressured to the client socket) —
            // in-flight bytes stay bounded end to end.
            for try await chunk in chunks where !chunk.isEmpty {
                var buffer = channel.allocator.buffer(capacity: chunk.count)
                buffer.writeBytes(chunk)
                try await channel.writeAndFlush(NIOAny(HTTPClientRequestPart.body(.byteBuffer(buffer)))).get()
            }
        }
        channel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil)), promise: nil)
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

    private static func makeSSLHandler(host: String) throws -> NIOSSLClientHandler {
        // IP-literal peers can't take an SNI/validation hostname.
        let serverName = isIPLiteral(host) ? nil : host
        return try NIOSSLClientHandler(context: SharedTLS.clientContext, serverHostname: serverName)
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
}

enum ForwarderError: Error {
    case invalidURL(String)
    case connectionClosed
}

/// Thread-safe holder so the stream's onTermination can close the upstream channel
/// once it's connected (connect happens asynchronously inside a Task).
private final class ChannelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: Channel?
    private var closed = false

    func set(_ channel: Channel) {
        lock.lock(); defer { lock.unlock() }
        if closed { channel.close(promise: nil) } else { self.channel = channel }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        channel?.close(promise: nil)
        channel = nil
    }
}

/// Relays one HTTP response upstream→stream as it arrives: `.head` then each body
/// chunk then `.end`, so SSE / long-poll / large downloads flow through instead of
/// being buffered. Closes the upstream channel when the response ends.
private final class StreamingResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let continuation: AsyncThrowingStream<UpstreamResponseEvent, Error>.Continuation
    private var finished = false

    init(continuation: AsyncThrowingStream<UpstreamResponseEvent, Error>.Continuation) {
        self.continuation = continuation
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
            continuation.finish(throwing: error)
        } else {
            continuation.yield(.end)
            continuation.finish()
        }
    }
}
