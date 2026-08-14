import Foundation
import Synchronization
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// Trailers survive both legs, and are captured on both.
///
/// A trailer field section is where gRPC returns its result — `grpc-status` /
/// `grpc-message` arrive *after* the body — so a proxy that drops it turns every
/// failed call into one that answered 200 and then stopped explaining. Loom dropped
/// it in both directions until 0.0.27: the response writer sent `.end(nil)`, the
/// request writer sent `.end(nil)`, and the capture had nowhere to record one.
///
/// Against a **real** local origin rather than a stub, because the thing under test
/// is the framing (chunked terminator, then the trailer section) and a stub cannot
/// get that wrong.
@Suite("Trailers", .timeLimit(.minutes(1)))
final class TrailerTests {
    private let group: MultiThreadedEventLoopGroup
    private let server: Channel
    private let origin: TrailerOrigin

    init() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let origin = TrailerOrigin()
        self.origin = origin
        server = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(TrailerEchoHandler(origin: origin))
                }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
    }

    deinit {
        try? server.close().wait()
        shutdownBlocking(group)
    }

    private var baseURL: URL { URL(string: "http://127.0.0.1:\(server.localAddress!.port!)")! }

    @Test func responseTrailersReachTheCallerAndTheResult() async throws {
        let forwarder = NIOStreamingForwarder(group: group)
        let result = try await forwarder.forward(
            method: "GET", url: baseURL.appendingPathComponent("/rpc"), headers: [], body: nil
        )

        #expect(result.statusCode == 200)
        #expect(result.trailers == [
            HeaderPair(name: "grpc-status", value: "13"),
            HeaderPair(name: "grpc-message", value: "boom"),
        ], "the origin's verdict arrives after the body; dropping it loses the whole answer")
    }

    /// The distinction the model insists on, at the wire boundary: an ordinary
    /// response must come back with `nil`, not an empty list. Otherwise every render
    /// grows a `trailers: []` key for traffic that never had a trailer section.
    @Test func aResponseWithNoTrailerSectionReportsNilNotEmpty() async throws {
        let forwarder = NIOStreamingForwarder(group: group)
        let result = try await forwarder.forward(
            method: "GET", url: baseURL.appendingPathComponent("/plain"), headers: [], body: nil
        )

        #expect(result.statusCode == 200)
        #expect(result.trailers == nil)
    }

    /// A buffered body carrying trailers is re-framed **chunked** upstream, because a
    /// `Content-Length` message has nowhere to put them (RFC 9112 §7.1.2). Before
    /// that re-framing the trailers were dropped on exactly the path a rule or a
    /// breakpoint puts every held exchange on.
    @Test func requestTrailersReachTheOrigin() async throws {
        let forwarder = NIOStreamingForwarder(group: group)
        let stream = forwarder.forwardStream(
            method: "POST", url: baseURL.appendingPathComponent("/rpc"), headers: [],
            body: .bytes(Data("payload".utf8), trailers: [HeaderPair(name: "x-checksum", value: "abc123")])
        )
        for try await _ in stream {}

        #expect(origin.requestBody == "payload")
        #expect(origin.requestTrailers == [HeaderPair(name: "x-checksum", value: "abc123")])
        #expect(origin.requestFraming == "chunked",
                "a Content-Length message cannot carry a trailer section, so the framing has to move")
    }

    /// End to end through the proxy, which is the assertion that matters to an
    /// operator: the trailer section reaches the client *and* lands on the flow. A
    /// relay that captured them but wrote `.end(nil)` would pass every test above.
    @Test func trailersAreRelayedToTheClientAndRecordedOnTheFlow() async throws {
        let engine = ProxyEngine(forwarder: NIOStreamingForwarder(group: group), caStore: InMemoryCAStore())
        let proxyPort = try await engine.start(port: 0)

        let received = group.next().makePromise(of: RawResponse.self)
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(RawRequestSender(
                    request: "GET \(self.baseURL.absoluteString)/rpc HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
                    promise: received
                ))
            }
            .connect(host: "127.0.0.1", port: proxyPort).get()
        defer { client.close(promise: nil) }

        let raw = try await received.futureResult.get()
        // The trailer section sits after the terminating `0` chunk, which is the one
        // place it can be on the wire — asserting on the text is asserting on framing.
        #expect(raw.text.contains("grpc-status: 13"),
                "the client has to be able to read the verdict; got:\n\(raw.text)")
        let headerBlockEnd = try #require(raw.text.range(of: "\r\n\r\n"))
        #expect(!raw.text[..<headerBlockEnd.lowerBound].contains("grpc-status"),
                "a trailer is not a header — it must not appear in the head")
        let terminator = try #require(raw.text.range(of: "\r\n0\r\n"))
        #expect(terminator.upperBound <= (raw.text.range(of: "grpc-status")?.lowerBound ?? raw.text.startIndex),
                "trailers belong after the terminating chunk; got:\n\(raw.text)")

        let flow = try #require(await awaitFlow(from: engine) {
            $0.request.url.hasSuffix("/rpc") && $0.response != nil
        })
        #expect(flow.response?.trailers == [
            HeaderPair(name: "grpc-status", value: "13"),
            HeaderPair(name: "grpc-message", value: "boom"),
        ])
        await engine.stopForTest()
    }
}

// MARK: - Test doubles

/// What the origin saw, so the request leg can be asserted on.
private final class TrailerOrigin: Sendable {
    private struct State {
        var body = ""
        var trailers: [HeaderPair]?
        var framing = ""
    }

    private let state = Mutex(State())

    var requestBody: String { state.withLock { $0.body } }
    var requestTrailers: [HeaderPair]? { state.withLock { $0.trailers } }
    /// `chunked` or the `Content-Length` value — the framing decision under test.
    var requestFraming: String { state.withLock { $0.framing } }

    func record(body: String, trailers: [HeaderPair]?, framing: String) {
        state.withLock { $0.body = body; $0.trailers = trailers; $0.framing = framing }
    }
}

/// An origin that answers `/rpc` with a chunked body followed by a trailer section,
/// and `/plain` with an ordinary body and none.
private final class TrailerEchoHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let origin: TrailerOrigin
    private var path = ""
    private var body = ""
    private var framing = ""

    init(origin: TrailerOrigin) { self.origin = origin }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            path = head.uri
            body = ""
            framing = head.headers.first(name: "transfer-encoding")
                ?? head.headers.first(name: "content-length")
                ?? ""
        case var .body(buffer):
            body += buffer.readString(length: buffer.readableBytes) ?? ""
        case let .end(trailers):
            origin.record(
                body: body,
                trailers: trailers.map { $0.map { HeaderPair(name: $0.name, value: $0.value) } },
                framing: framing
            )
            respond(context: context)
        }
    }

    private func respond(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        let withTrailers = path.hasSuffix("/rpc")
        if withTrailers {
            headers.add(name: "Transfer-Encoding", value: "chunked")
            // Advertised as the spec asks, and deliberately *not* what Loom keys off:
            // the trailer section itself is the fact, and an origin that omits this
            // header still sends one.
            headers.add(name: "Trailer", value: "grpc-status, grpc-message")
        } else {
            headers.add(name: "Content-Length", value: "2")
        }
        headers.add(name: "Content-Type", value: "application/grpc")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: 2)
        buffer.writeString("ok")
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        var trailers: HTTPHeaders?
        if withTrailers {
            var section = HTTPHeaders()
            section.add(name: "grpc-status", value: "13")
            section.add(name: "grpc-message", value: "boom")
            trailers = section
        }
        context.writeAndFlush(wrapOutboundOut(.end(trailers)), promise: nil)
    }
}

private struct RawResponse: Sendable { let text: String }

/// Writes one raw request and collects the whole reply as text, so the *framing* can
/// be asserted on rather than a parser's interpretation of it. Completes on the
/// chunked terminator that follows a trailer section.
private final class RawRequestSender: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let request: String
    private let promise: EventLoopPromise<RawResponse>
    private var seen = ""
    private var done = false

    init(request: String, promise: EventLoopPromise<RawResponse>) {
        self.request = request
        self.promise = promise
    }

    func channelActive(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        seen += buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
        // A chunked message with trailers ends `0 CRLF <trailers> CRLF` — waiting for
        // the blank line after the trailer section is what proves the whole section
        // arrived rather than its first field.
        guard !done, seen.contains("grpc-message"), seen.hasSuffix("\r\n\r\n") else { return }
        done = true
        promise.succeed(RawResponse(text: seen))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
    }
}
