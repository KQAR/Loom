import Foundation
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
@Suite final class NIOStreamingForwarderTests {
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
        try? group.syncShutdownGracefully()
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

    @Test func forwardStream_deliversChunksInOrder() async throws {
        // A chunked server that emits three body parts with small gaps, so they
        // arrive as distinct reads and prove the response streams (not buffers).
        let chunkGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? chunkGroup.syncShutdownGracefully() }
        let chunkServer = try ServerBootstrap(group: chunkGroup)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                ch.pipeline.configureHTTPServerPipeline().flatMap {
                    ch.pipeline.addHandler(ChunkingResponder())
                }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { try? chunkServer.close().wait() }
        let url = URL(string: "http://127.0.0.1:\(chunkServer.localAddress!.port!)/stream")!

        let forwarder = NIOStreamingForwarder(group: group)
        var order: [String] = []
        var bodies: [String] = []
        for try await event in forwarder.forwardStream(method: "GET", url: url, headers: [], body: .bytes(nil)) {
            switch event {
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
private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _method = ""
    private var _uri = ""
    private var _headers: [(String, String)] = []
    private var _body = ""

    func record(method: String, uri: String, headers: [(String, String)], body: String) {
        lock.lock(); defer { lock.unlock() }
        _method = method; _uri = uri; _headers = headers; _body = body
    }
    var method: String { lock.lock(); defer { lock.unlock() }; return _method }
    var uri: String { lock.lock(); defer { lock.unlock() }; return _uri }
    var bodyText: String { lock.lock(); defer { lock.unlock() }; return _body }
    func headerValue(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return _headers.first { $0.0.lowercased() == name.lowercased() }?.1
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
