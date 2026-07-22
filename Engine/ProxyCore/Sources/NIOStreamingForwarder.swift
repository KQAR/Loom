import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHTTPCompression
import NIOSSL
import SharedModels

/// Upstream client built directly on SwiftNIO (M4), replacing `URLSessionForwarder`.
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
        guard let host = url.host else {
            throw ForwarderError.invalidURL(url.absoluteString)
        }
        let isTLS = (url.scheme?.lowercased() == "https")
        let port = url.port ?? (isTLS ? 443 : 80)

        // Build the TLS context up front so the channel initializer can't throw.
        let sslHandler: NIOSSLClientHandler? = try isTLS ? Self.makeSSLHandler(host: host) : nil

        let promise = group.next().makePromise(of: ForwardResult.self)
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(connectTimeout)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                let tlsFuture: EventLoopFuture<Void> = sslHandler.map {
                    channel.pipeline.addHandler($0)
                } ?? channel.eventLoop.makeSucceededVoidFuture()
                return tlsFuture
                    .flatMap { channel.pipeline.addHTTPClientHandlers() }
                    // Decompress gzip/deflate so the captured body is plaintext; the
                    // now-wrong Content-Encoding/Length are stripped from the result.
                    .flatMap { channel.pipeline.addHandler(NIOHTTPResponseDecompressor(limit: .none)) }
                    .flatMap { channel.pipeline.addHandler(ResponseCollector(promise: promise)) }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            promise.fail(error)
            throw error
        }

        Self.writeRequest(channel: channel, method: method, url: url, host: host, port: port, headers: headers, body: body)

        do {
            let result = try await promise.futureResult.get()
            channel.close(promise: nil)
            return result
        } catch {
            channel.close(promise: nil)
            throw error
        }
    }

    // MARK: - Request

    private static func writeRequest(
        channel: Channel, method: String, url: URL, host: String, port: Int,
        headers: [HeaderPair], body: Data?
    ) {
        var httpHeaders = HTTPHeaders()
        var sawHost = false
        for header in headers {
            let lower = header.name.lowercased()
            // We set Content-Length ourselves; drop hop-by-hop and any framing the
            // client stack must own. Host is kept if present (so keepHostHeader works).
            if HTTPUtil.isHopByHop(lower) || lower == "content-length" || lower == "transfer-encoding" { continue }
            if lower == "host" { sawHost = true }
            httpHeaders.add(name: header.name, value: header.value)
        }
        if !sawHost {
            let defaultPort = url.scheme?.lowercased() == "https" ? 443 : 80
            httpHeaders.add(name: "Host", value: port == defaultPort ? host : "\(host):\(port)")
        }
        httpHeaders.replaceOrAdd(name: "Content-Length", value: String(body?.count ?? 0))

        let head = HTTPRequestHead(
            version: .http1_1,
            method: httpMethod(method),
            uri: requestURI(url),
            headers: httpHeaders
        )

        channel.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
        if let body, !body.isEmpty {
            var buffer = channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            channel.write(NIOAny(HTTPClientRequestPart.body(.byteBuffer(buffer))), promise: nil)
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
        let context = try NIOSSLContext(configuration: .makeClientConfiguration())
        // IP-literal peers can't take an SNI/validation hostname.
        let serverName = isIPLiteral(host) ? nil : host
        return try NIOSSLClientHandler(context: context, serverHostname: serverName)
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

/// Collects one HTTP response (head + full body) and fulfills the promise on `.end`.
private final class ResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<ForwardResult>
    private var head: HTTPResponseHead?
    private var body: ByteBuffer?
    private var finished = false

    init(promise: EventLoopPromise<ForwardResult>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            self.head = head
        case var .body(chunk):
            if body == nil { body = context.channel.allocator.buffer(capacity: chunk.readableBytes) }
            body?.writeBuffer(&chunk)
        case .end:
            complete(context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !finished { finish(.failure(ForwarderError.connectionClosed)) }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !finished { finish(.failure(error)) }
        context.close(promise: nil)
    }

    private func complete(context: ChannelHandlerContext) {
        guard let head else { finish(.failure(ForwarderError.connectionClosed)); return }
        let bytes = body.flatMap { buf in buf.getBytes(at: buf.readerIndex, length: buf.readableBytes) } ?? []
        let rawHeaders = HTTPUtil.headerPairs(head.headers)
        // Body was decompressed by NIOHTTPResponseDecompressor, so Content-Encoding /
        // Content-Length no longer describe the bytes — drop them (writer recomputes).
        let result = ForwardResult(
            statusCode: Int(head.status.code),
            headers: HTTPUtil.sanitizeDecodedResponseHeaders(rawHeaders),
            body: Data(bytes)
        )
        finish(.success(result))
    }

    private func finish(_ result: Result<ForwardResult, Error>) {
        guard !finished else { return }
        finished = true
        promise.completeWith(result)
    }
}
