import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyCore
import SharedModels

/// Exercises the M4 NIO upstream client against a real local NIO HTTP/1.1 server:
/// method / headers / body reach upstream, status + body come back, and the Host
/// header is Loom-controlled (default follows the URL; a caller-supplied Host is
/// preserved, which is what a keepHostHeader map-remote rule relies on).
final class NIOStreamingForwarderTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var server: Channel!
    private var recorder: RequestRecorder!

    override func setUpWithError() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        recorder = RequestRecorder()
        let recorder = self.recorder!
        server = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                ch.pipeline.configureHTTPServerPipeline().flatMap {
                    ch.pipeline.addHandler(EchoBackHandler(recorder: recorder))
                }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
    }

    override func tearDownWithError() throws {
        try? server.close().wait()
        try? group.syncShutdownGracefully()
    }

    private var baseURL: URL { URL(string: "http://127.0.0.1:\(server.localAddress!.port!)")! }

    func test_postRoundTrip_sendsMethodHeadersBody_andReturnsResponse() async throws {
        let forwarder = NIOStreamingForwarder(group: group)
        let result = try await forwarder.forward(
            method: "POST",
            url: baseURL.appendingPathComponent("/echo"),
            headers: [HeaderPair(name: "X-Test", value: "loom")],
            body: Data("hello".utf8)
        )

        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(String(decoding: result.body, as: UTF8.self), "hello")
        XCTAssertEqual(recorder.method, "POST")
        XCTAssertEqual(recorder.uri, "/echo")
        XCTAssertEqual(recorder.headerValue("X-Test"), "loom")
        XCTAssertEqual(recorder.bodyText, "hello")
    }

    func test_defaultHost_followsURL() async throws {
        let forwarder = NIOStreamingForwarder(group: group)
        _ = try await forwarder.forward(method: "GET", url: baseURL, headers: [], body: nil)
        XCTAssertEqual(recorder.headerValue("Host"), "127.0.0.1:\(server.localAddress!.port!)")
    }

    func test_callerHostHeader_isPreserved() async throws {
        let forwarder = NIOStreamingForwarder(group: group)
        _ = try await forwarder.forward(
            method: "GET", url: baseURL,
            headers: [HeaderPair(name: "Host", value: "keep.example.com")], body: nil
        )
        XCTAssertEqual(recorder.headerValue("Host"), "keep.example.com",
                       "a caller-supplied Host must survive (keepHostHeader relies on this)")
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
