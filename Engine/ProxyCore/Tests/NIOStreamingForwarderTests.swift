import Foundation
import Synchronization
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// Exercises the M4 NIO upstream client against a real local NIO HTTP/1.1 server:
/// method / headers / body reach upstream, status + body come back, and the Host
/// header is Loom-controlled (default follows the URL; a caller-supplied Host is
/// preserved, which is what a keepHostHeader map-remote rule relies on).
/// A class suite so `init`/`deinit` stand in for setUp/tearDown — a fresh local
/// server per test.
@Suite("NIO streaming forwarder", .timeLimit(.minutes(1)))
final class NIOStreamingForwarderTests {
    private let group: MultiThreadedEventLoopGroup
    private let server: Channel
    private let recorder: RequestRecorder

    init() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let recorder = RequestRecorder()
        self.recorder = recorder
        server = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                ch.pipeline.configureHTTPServerPipeline().flatMap {
                    ch.pipeline.addHandler(EchoBackHandler(recorder: recorder))
                }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
    }

    deinit {
        try? server.close().wait()
        shutdownBlocking(group)
    }

    private var baseURL: URL { URL(string: "http://127.0.0.1:\(server.localAddress!.port!)")! }

    @Test func postRoundTrip_sendsMethodHeadersBody_andReturnsResponse() async throws {
        let forwarder = NIOStreamingForwarder(group: group)
        let result = try await forwarder.forward(
            method: "POST",
            url: baseURL.appendingPathComponent("/echo"),
            headers: [HeaderPair(name: "X-Test", value: "loom")],
            body: Data("hello".utf8)
        )

        #expect(result.statusCode == 200)
        #expect(String(decoding: result.body, as: UTF8.self) == "hello")
        #expect(recorder.method == "POST")
        #expect(recorder.uri == "/echo")
        #expect(recorder.headerValue("X-Test") == "loom")
        #expect(recorder.bodyText == "hello")
    }

    @Test func defaultHost_followsURL() async throws {
        let forwarder = NIOStreamingForwarder(group: group)
        _ = try await forwarder.forward(method: "GET", url: baseURL, headers: [], body: nil)
        #expect(recorder.headerValue("Host") == "127.0.0.1:\(server.localAddress!.port!)")
    }

    @Test func callerHostHeader_isPreserved() async throws {
        let forwarder = NIOStreamingForwarder(group: group)
        _ = try await forwarder.forward(
            method: "GET", url: baseURL,
            headers: [HeaderPair(name: "Host", value: "keep.example.com")], body: nil
        )
        #expect(recorder.headerValue("Host") == "keep.example.com",
                "a caller-supplied Host must survive (keepHostHeader relies on this)")
    }

    @Test func acceptEncoding_isPinnedToWhatLoomCanDecode() async throws {
        // The client's list (browsers advertise br/zstd) must NOT reach the origin:
        // the decompressor only inflates gzip/deflate, so any other encoding would
        // pass through still-compressed after its Content-Encoding was stripped.
        let forwarder = NIOStreamingForwarder(group: group)
        _ = try await forwarder.forward(
            method: "GET", url: baseURL,
            headers: [HeaderPair(name: "Accept-Encoding", value: "gzip, deflate, br, zstd")], body: nil
        )
        #expect(recorder.headerValue("Accept-Encoding") == "gzip, deflate")
    }

    @Test func acceptEncoding_isPinnedEvenWhenTheClientSentNone() async throws {
        let forwarder = NIOStreamingForwarder(group: group)
        _ = try await forwarder.forward(method: "GET", url: baseURL, headers: [], body: nil)
        #expect(recorder.headerValue("Accept-Encoding") == "gzip, deflate")
    }

    @Test func deflateResponse_reachesTheCallerAsPlaintext_withEncodingHeadersGone() async throws {
        // End-to-end pin of the decode-then-sanitize contract this forwarder's
        // Known Issues entry exists for: a compressed upstream body must come back
        // inflated, with Content-Encoding/Content-Length no longer lying about it.
        let plaintext = "hello compressed world, hello compressed world"
        let deflateGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { shutdownBlocking(deflateGroup) }
        let deflateServer = try await ServerBootstrap(group: deflateGroup)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                ch.pipeline.configureHTTPServerPipeline().flatMap {
                    ch.pipeline.addHandler(DeflateResponder(plaintext: plaintext))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { deflateServer.close(promise: nil) }
        let url = URL(string: "http://127.0.0.1:\(deflateServer.localAddress!.port!)/compressed")!

        let forwarder = NIOStreamingForwarder(group: group)
        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)

        #expect(String(decoding: result.body, as: UTF8.self) == plaintext)
        #expect(result.headers.allSatisfy { $0.name.lowercased() != "content-encoding" },
                "a decoded body must not keep the Content-Encoding it no longer has")
        #expect(result.headers.allSatisfy { $0.name.lowercased() != "content-length" },
                "the compressed length no longer matches the decoded body")
    }

    @Test func unencodedResponse_keepsItsContentLength() async throws {
        // The echo server answers with Content-Length and no Content-Encoding, so
        // nothing was decoded and the length still describes the bytes. It must
        // survive to the caller — the capture shows what the origin sent, and the
        // bodyless writer has a length to preserve for `curl -I`.
        let forwarder = NIOStreamingForwarder(group: group)
        let result = try await forwarder.forward(
            method: "POST", url: baseURL, headers: [], body: Data("hello".utf8)
        )
        let length = result.headers.first { $0.name.lowercased() == "content-length" }
        #expect(length?.value == "5")
    }

    // MARK: - Transport

    @Test func transport_namesTheOriginAndWhetherTheSocketWasNew() async throws {
        // Two requests through one forwarder: the first opens a connection, the
        // second leases it back. Without the second reading `reused == true` the
        // pool could stop working and nothing on any surface would say so.
        let forwarder = NIOStreamingForwarder(group: group)
        let first = try await forwarder.forward(method: "GET", url: baseURL, headers: [], body: nil)
        let second = try await forwarder.forward(method: "GET", url: baseURL, headers: [], body: nil)

        let port = server.localAddress!.port!
        #expect(first.transport?.remoteAddress == "127.0.0.1:\(port)")
        #expect(first.transport?.connectionReused == false)
        #expect(second.transport?.connectionReused == true)
        // Plaintext upstream: there is no handshake to describe, and an empty
        // reading here would read as "measured, and nothing negotiated".
        #expect(first.transport?.upstreamTLS == nil)
    }

    @Test func transport_breaksTheConnectionSetupIntoPhases() async throws {
        // The first request to an origin pays DNS + TCP (+ TLS, not here — this
        // server is plaintext); the second pays none of it. Reporting the first
        // connection's setup on the reuse would inflate exactly the number someone
        // reads this to explain.
        let forwarder = NIOStreamingForwarder(group: group)
        let first = try await forwarder.forward(method: "GET", url: baseURL, headers: [], body: nil)
        let second = try await forwarder.forward(method: "GET", url: baseURL, headers: [], body: nil)

        let setup = try #require(first.transport?.setup)
        #expect(setup.tcpMS != nil, "a fresh connection measured its TCP connect")
        #expect(setup.tcpMS ?? -1 >= 0)
        // Loopback by IP literal: nothing to resolve, and 0 ms would suggest a
        // lookup happened.
        #expect(setup.dnsMS == nil)
        // Plaintext upstream: no handshake to time.
        #expect(setup.tlsHandshakeMS == nil)
        #expect(setup.totalMS == setup.tcpMS)

        #expect(second.transport?.setup == nil, "a reused connection paid none of it")
        #expect(second.transport?.connectionReused == true)
    }

    @Test func transport_timesTheRequestSendPerExchange() async throws {
        // Per-exchange, unlike the setup phases — a reused connection still writes
        // its own request, and both of these are on a plaintext upstream, where the
        // socket is writable the moment `connect()` returns.
        let forwarder = NIOStreamingForwarder(group: group)
        let first = try await forwarder.forward(
            method: "POST", url: baseURL, headers: [], body: Data("hello".utf8)
        )
        let second = try await forwarder.forward(
            method: "POST", url: baseURL, headers: [], body: Data("hello".utf8)
        )
        #expect(first.transport?.requestSendMS != nil)
        #expect(second.transport?.connectionReused == true)
        #expect(second.transport?.requestSendMS != nil)
    }

    @Test func transport_reportsTheWireSizeOfACompressedBody() async throws {
        // The encoded size exists nowhere else once the forwarder has inflated the
        // body and stripped the headers that described it, so this is the only
        // reading of "how much bandwidth did this response cost".
        let plaintext = String(repeating: "hello compressed world, ", count: 40)
        let deflateGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { shutdownBlocking(deflateGroup) }
        let deflateServer = try await ServerBootstrap(group: deflateGroup)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                ch.pipeline.configureHTTPServerPipeline().flatMap {
                    ch.pipeline.addHandler(DeflateResponder(plaintext: plaintext))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { deflateServer.close(promise: nil) }
        let url = URL(string: "http://127.0.0.1:\(deflateServer.localAddress!.port!)/compressed")!

        let forwarder = NIOStreamingForwarder(group: group)
        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)

        #expect(result.transport?.responseContentEncoding == "deflate")
        let encoded = try #require(result.transport?.responseEncodedBodyBytes)
        #expect(encoded > 0)
        #expect(encoded < result.body.count, "the point of the field is that it differs from the decoded size")
    }

    @Test func transport_countsAnUnencodedBodyAtItsOwnSize() async throws {
        // No compression: the wire size and the decoded size agree, and the
        // counter must still report rather than stay silent — a nil here would be
        // indistinguishable from a body it failed to observe.
        let forwarder = NIOStreamingForwarder(group: group)
        let result = try await forwarder.forward(
            method: "POST", url: baseURL, headers: [], body: Data("hello".utf8)
        )
        #expect(result.transport?.responseEncodedBodyBytes == result.body.count)
        #expect(result.transport?.responseContentEncoding == nil)
    }

    @Test func forwardStream_deliversChunksInOrder() async throws {
        // A chunked server that emits three body parts with small gaps, so they
        // arrive as distinct reads and prove the response streams (not buffers).
        let chunkGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { shutdownBlocking(chunkGroup) }
        let chunkServer = try await ServerBootstrap(group: chunkGroup)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                ch.pipeline.configureHTTPServerPipeline().flatMap {
                    ch.pipeline.addHandler(ChunkingResponder())
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { chunkServer.close(promise: nil) }
        let url = URL(string: "http://127.0.0.1:\(chunkServer.localAddress!.port!)/stream")!

        let forwarder = NIOStreamingForwarder(group: group)
        var order: [String] = []
        var bodies: [String] = []
        for try await event in forwarder.forwardStream(method: "GET", url: url, headers: [], body: .bytes(nil)) {
            switch event {
            case .metadata, .transport: break
            case .head: order.append("head")
            case let .body(data): order.append("body"); bodies.append(String(decoding: data, as: UTF8.self))
            case .end: order.append("end")
            }
        }

        #expect(order.first == "head", "head must arrive first")
        #expect(order.last == "end", "end must arrive last")
        #expect(bodies.count >= 2, "body should arrive in multiple streamed chunks")
        #expect(bodies.joined() == "part1part2part3")
    }
}

/// Responds with a zlib-deflated body and `Content-Encoding: deflate`, so the
/// forwarder's decompressor has real compressed bytes to inflate.
private final class DeflateResponder: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let plaintext: String
    init(plaintext: String) { self.plaintext = plaintext }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        let body = Self.zlibDeflate(Data(plaintext.utf8))
        var headers = HTTPHeaders()
        headers.add(name: "Content-Encoding", value: "deflate")
        headers.add(name: "Content-Length", value: String(body.count))
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    /// RFC 1950 zlib stream: 2-byte header + raw DEFLATE (Compression framework's
    /// `.zlib` is raw per its docs) + Adler-32 of the plaintext.
    private static func zlibDeflate(_ original: Data) -> Data {
        let raw = (try? (original as NSData).compressed(using: .zlib) as Data) ?? Data()
        var out = Data([0x78, 0x9C])
        out.append(raw)
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in original {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let adler = (b << 16) | a
        out.append(contentsOf: [
            UInt8((adler >> 24) & 0xFF), UInt8((adler >> 16) & 0xFF),
            UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF),
        ])
        return out
    }
}

/// Responds with a chunked body written in three spaced-out parts.
private final class ChunkingResponder: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        var headers = HTTPHeaders()
        headers.add(name: "Transfer-Encoding", value: "chunked")
        context.writeAndFlush(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)

        let loop = context.eventLoop
        let parts = ["part1", "part2", "part3"]
        for (index, part) in parts.enumerated() {
            loop.scheduleTask(in: .milliseconds(Int64(index) * 30)) {
                var buffer = context.channel.allocator.buffer(capacity: part.utf8.count)
                buffer.writeString(part)
                context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            }
        }
        loop.scheduleTask(in: .milliseconds(Int64(parts.count) * 30)) {
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

/// Records the last request the server saw and echoes its body back with 200.
private final class RequestRecorder: Sendable {
    private struct Seen {
        var method = ""
        var uri = ""
        var headers: [(String, String)] = []
        var body = ""
    }

    private let seen = Mutex(Seen())

    func record(method: String, uri: String, headers: [(String, String)], body: String) {
        seen.withLock { $0 = Seen(method: method, uri: uri, headers: headers, body: body) }
    }
    var method: String { seen.withLock { $0.method } }
    var uri: String { seen.withLock { $0.uri } }
    var bodyText: String { seen.withLock { $0.body } }
    func headerValue(_ name: String) -> String? {
        seen.withLock { $0.headers.first { $0.0.lowercased() == name.lowercased() }?.1 }
    }
}

private final class EchoBackHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let recorder: RequestRecorder
    private var head: HTTPRequestHead?
    private var body = ""

    init(recorder: RequestRecorder) { self.recorder = recorder }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            self.head = head
            body = ""
        case var .body(buffer):
            body += buffer.readString(length: buffer.readableBytes) ?? ""
        case .end:
            guard let head else { return }
            recorder.record(
                method: head.method.rawValue, uri: head.uri,
                headers: head.headers.map { ($0.name, $0.value) }, body: body
            )
            var responseHeaders = HTTPHeaders()
            responseHeaders.add(name: "Content-Length", value: String(body.utf8.count))
            let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: responseHeaders)
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            var buf = context.channel.allocator.buffer(capacity: body.utf8.count)
            buf.writeString(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}
