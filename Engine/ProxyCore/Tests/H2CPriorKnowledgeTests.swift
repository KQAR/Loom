import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// Cleartext HTTP/2 with prior knowledge (RFC 9113 §3.4) is captured, not relayed.
///
/// This closes the last protocol Loom could see and deliberately declined to read.
/// The preface reads exactly like an HTTP/1 request line — `PRI * HTTP/2.0` — so
/// `ProtocolSniff` always had to tell it apart from one; it just used to answer
/// `.opaque` and hand the tunnel to a byte relay, on the reasoning that h2 needed a
/// negotiated ALPN. It does not: ALPN only *says* h2, and prior knowledge says the
/// same thing more directly.
///
/// The cost of the old answer is the one `TunneledHostLog` exists to prevent. An
/// unread relay records no flow, so gRPC over cleartext, a Go service behind
/// `h2c.NewHandler`, and any internal HTTP/2 endpoint reached without TLS produced a
/// capture identical to a client that never ran.
@Suite("h2c prior knowledge", .timeLimit(.minutes(1)))
struct H2CPriorKnowledgeTests {
    @Test func capturesCleartextHTTP2InsideACONNECT() async throws {
        let responseBody = #"{"ok":true,"via":"loom-h2c"}"#
        let forwarder = StubForwarder(status: 200, body: Data(responseBody.utf8))
        let engine = ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())
        let port = try await engine.start(port: 0)
        // Scope on and covering everything: this must be decided by the *bytes*, not
        // by the scope. A tunnel carrying no TLS is not the SSL scope's business, and
        // a sniff that quietly deferred to it would break the moment someone excluded
        // the host to fix something else.
        await engine.setSSLScope(SSLScope(enabled: true, include: ["*"]))

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownBlocking(group) }
        let acked = group.next().makePromise(of: Void.self)

        let connect = CONNECTAckHandler(
            request: "CONNECT grpc.test:8080 HTTP/1.1\r\nHost: grpc.test:8080\r\n\r\n",
            acked: acked
        )
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(connect) }
            .connect(host: "127.0.0.1", port: port).get()
        defer { client.close(promise: nil) }

        try await acked.futureResult.get()
        try await client.pipeline.removeHandler(connect).get()

        // No TLS handler: an ordinary NIO h2 *client* on a bare socket sends the
        // preface and SETTINGS itself, which is exactly what a prior-knowledge client
        // is. Nothing here tells Loom what protocol this is.
        let multiplexer = try await client.configureHTTP2Pipeline(mode: .client).get()

        let answered = group.next().makePromise(of: H2CResponse.self)
        multiplexer.createStreamChannel(promise: nil) { stream in
            stream.pipeline.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .http)).flatMap {
                stream.pipeline.addHandler(H2CRequestHandler(promise: answered, path: "/pkg.Svc/Method"))
            }
        }

        let response = try await answered.futureResult.get()
        #expect(response.status == 200, "the exchange must complete, not merely be recognised")
        #expect(response.body.contains("loom-h2c"))

        let flow = try #require(await awaitFlow(from: engine) {
            $0.request.url.contains("/pkg.Svc/Method") && $0.response != nil
        }, "a relayed tunnel records no flow at all — that is the bug this pins")
        #expect(flow.request.url == "http://grpc.test:8080/pkg.Svc/Method",
                "cleartext h2 must be recorded as http, never https")
        #expect(flow.request.httpVersion == "HTTP/2",
                "the h2↔h1 codec hands over an HTTP/1.1 head, so the version is stated, not derived")
        #expect(flow.request.headers.contains { $0.name.lowercased() == "x-loom-test" },
                "the request inside the tunnel is what the operator came to read")
        #expect(forwarder.lastURL?.absoluteString == "http://grpc.test:8080/pkg.Svc/Method",
                "the re-sent leg stays cleartext too")

        // And it is not listed as unread: a host that got captured must not also
        // appear on the surface an operator reads to find hosts that didn't.
        #expect(!TunneledHostLog.shared.snapshot().hosts.contains { $0.host == "grpc.test" },
                "captured h2c must not be recorded as a tunnel")

        // Terminal, at the end of the body rather than in a `defer`, for the reason
        // `EngineTeardown.swift` gives: a `defer` cannot await.
        await engine.stopForTest()
    }

    /// The whole gRPC shape, end to end: an h2c client, Loom in the middle, an h2c
    /// origin — and a `grpc-status` trailer that has to survive both legs.
    ///
    /// **Disabled while `NIOStreamingForwarder.cleartextHTTP2Upstream` is off.** This
    /// passes — it was written against a real cleartext origin and the whole gRPC
    /// shape completes, trailers included — but the leg it exercises is switched off
    /// because it stalls under load (`docs/decisions/h2c-upstream-stall.md`). Flip the
    /// flag and this test comes back with it; that pairing is the point of leaving it
    /// here rather than deleting it.
    @Test(.disabled("h2c upstream is gated off — see NIOStreamingForwarder.cleartextHTTP2Upstream"))
    func anH2CClientGetsAnH2CUpstreamLegAndItsTrailers() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { shutdownBlocking(group) }

        // A cleartext HTTP/2 origin — no ALPN, no TLS. An HTTP/1.1 request to it
        // does not parse, which is what makes the assertions below meaningful.
        let origin = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.configureHTTP2Pipeline(mode: .server) { stream in
                    stream.eventLoop.makeCompletedFuture {
                        let sync = stream.pipeline.syncOperations
                        try sync.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())
                        try sync.addHandler(GRPCishHandler())
                    }
                }.map { _ in }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { origin.close(promise: nil) }
        let originPort = try #require(origin.localAddress?.port)

        let engine = ProxyEngine(forwarder: NIOStreamingForwarder(group: group), caStore: InMemoryCAStore())
        let proxyPort = try await engine.start(port: 0)
        await engine.setSSLScope(SSLScope(enabled: true, include: ["*"]))

        let acked = group.next().makePromise(of: Void.self)
        let connect = CONNECTAckHandler(
            request: "CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n",
            acked: acked
        )
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(connect) }
            .connect(host: "127.0.0.1", port: proxyPort).get()
        defer { client.close(promise: nil) }

        try await acked.futureResult.get()
        try await client.pipeline.removeHandler(connect).get()

        let multiplexer = try await client.configureHTTP2Pipeline(mode: .client).get()
        let answered = group.next().makePromise(of: H2CResponse.self)
        multiplexer.createStreamChannel(promise: nil) { stream in
            stream.pipeline.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .http)).flatMap {
                stream.pipeline.addHandler(H2CRequestHandler(
                    promise: answered, path: "/pkg.Svc/Failing",
                    extraHeaders: [("cookie", "a=1; user_session=abc; z=9")]
                ))
            }
        }

        let response = try await answered.futureResult.get()
        #expect(response.status == 200, "an h1 leg would never have reached this origin at all")
        #expect(response.trailers.first { $0.name == "grpc-status" }?.value == "13",
                "the verdict rides the trailers; it is the whole answer of a gRPC call")

        let flow = try #require(await awaitFlow(from: engine) {
            $0.request.url.contains("/pkg.Svc/Failing") && $0.response != nil
        })
        #expect(flow.request.httpVersion == "HTTP/2")
        #expect(flow.response?.httpVersion == "HTTP/2",
                "the response's version is Loom's *upstream* hop — it must not report the h2↔h1 codec's shape")
        #expect(flow.response?.trailers?.first { $0.name == "grpc-status" }?.value == "13",
                "and the capture has to hold it, or the operator sees a 200 with no explanation")

        await engine.stopForTest()
    }
}

// MARK: - Test doubles

private struct H2CResponse: Sendable {
    let status: Int
    let body: String
    let trailers: [HeaderPair]
}

/// An origin that answers like a gRPC server does: 200 with a body, and the actual
/// verdict in the response trailers.
private final class GRPCishHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/grpc")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: 2)
        buffer.writeString("ok")
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        var trailers = HTTPHeaders()
        trailers.add(name: "grpc-status", value: "13")
        trailers.add(name: "grpc-message", value: "internal")
        context.writeAndFlush(wrapOutboundOut(.end(trailers)), promise: nil)
    }
}

/// One GET on an h2 stream channel (h1-shaped by the codec), collecting the answer.
private final class H2CRequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let promise: EventLoopPromise<H2CResponse>
    private let path: String
    private let extraHeaders: [(String, String)]
    private var status = 0
    private var body = ""
    private var trailers: [HeaderPair] = []

    init(promise: EventLoopPromise<H2CResponse>, path: String, extraHeaders: [(String, String)] = []) {
        self.promise = promise
        self.path = path
        self.extraHeaders = extraHeaders
    }

    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "host", value: "grpc.test:8080")
        headers.add(name: "x-loom-test", value: "h2c-prior-knowledge")
        for (name, value) in extraHeaders { headers.add(name: name, value: value) }
        let head = HTTPRequestHead(version: .init(major: 1, minor: 1), method: .GET, uri: path, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head): status = Int(head.status.code)
        case var .body(buffer): body += buffer.readString(length: buffer.readableBytes) ?? ""
        case let .end(section):
            trailers = section.map { $0.map { HeaderPair(name: $0.name, value: $0.value) } } ?? []
            promise.succeed(H2CResponse(status: status, body: body, trailers: trailers))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
    }
}

/// Chasing the real-machine hang: through the full engine, an h2c client leg and an
/// h2c upstream leg, several exchanges at once.
///
/// The signature being hunted, captured from a live run with a byte logger on the
/// origin: Loom opens the upstream connection, sends the preface and SETTINGS, ACKs
/// the origin's SETTINGS — and then never sends the request HEADERS. The exchange
/// hangs with no error, and the flow sits at status 0. Serial in-process exchanges
/// do not reproduce it, so concurrency is the next variable.
@Suite("h2c under concurrency", .timeLimit(.minutes(1)))
struct H2CConcurrencyTests {
    /// **Disabled: this is a live investigation, not a passing guard.** It fails, and
    /// it is checked in because it is the only reproduction anyone has.
    ///
    /// Measured with a 30 s per-request deadline and the rest of `ProxyCoreTests`
    /// running alongside it (the load is part of the reproduction — alone it passes):
    /// 39 of 40 requests are captured, **38 of them are answered by the origin**, and
    /// only a handful of those answers reach the client. The response writes
    /// themselves report no failure, so the bytes leave `HTTPUtil` and do not arrive.
    ///
    /// What is already ruled out, each by a run of this test: upstream connect
    /// coalescing, h2 connection sharing (one connection per exchange behaves the
    /// same), a first-stream activation race (a 50 ms delay changes nothing), the
    /// cookie crumb split, and rules/breakpoints.
    ///
    /// One caveat before trusting the numbers: they moved when the deadline moved
    /// (5 s → 30 s took captured flows from 30 to 39), which means some of what looks
    /// like loss is starvation of a four-loop group shared by 40 clients, the engine
    /// and the origin. Whoever picks this up should first make the client's own
    /// arrival of bytes observable — a raw byte counter on the tunnel — so "slow" and
    /// "lost" stop being the same measurement.
    @Test(.disabled("Reproduction for the h2c response-delivery stall; see the comment above."))
    func manyConcurrentH2CExchangesAllComplete() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        defer { shutdownBlocking(group) }

        let origin = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.configureHTTP2Pipeline(mode: .server) { stream in
                    stream.eventLoop.makeCompletedFuture {
                        let sync = stream.pipeline.syncOperations
                        try sync.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())
                        try sync.addHandler(GRPCishHandler())
                    }
                }.map { _ in }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { origin.close(promise: nil) }
        let originPort = try #require(origin.localAddress?.port)

        let engine = ProxyEngine(forwarder: NIOStreamingForwarder(group: group), caStore: InMemoryCAStore())
        let proxyPort = try await engine.start(port: 0)
        await engine.setSSLScope(SSLScope(enabled: true, include: ["*"]))

        // Each iteration is a *separate* client connection — one CONNECT tunnel, one
        // h2c client leg — which is what `curl` does per invocation.
        try await withThrowingTaskGroup(of: Int.self) { tasks in
            for index in 0 ..< 40 {
                tasks.addTask {
                    let acked = group.next().makePromise(of: Void.self)
                    let connect = CONNECTAckHandler(
                        request: "CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n",
                        acked: acked
                    )
                    let client = try await ClientBootstrap(group: group)
                        .channelInitializer { $0.pipeline.addHandler(connect) }
                        .connect(host: "127.0.0.1", port: proxyPort).get()
                    defer { client.close(promise: nil) }
                    try await acked.futureResult.get()
                    try await client.pipeline.removeHandler(connect).get()

                    let multiplexer = try await client.configureHTTP2Pipeline(mode: .client).get()
                    let answered = group.next().makePromise(of: H2CResponse.self)
                    multiplexer.createStreamChannel(promise: nil) { stream in
                        stream.pipeline.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .http)).flatMap {
                            stream.pipeline.addHandler(H2CRequestHandler(promise: answered, path: "/rpc/\(index)"))
                        }
                    }
                    // Per-request deadline rather than the suite's: a hang here has to
                    // report *which* half stalled, not just that a minute passed.
                    group.next().scheduleTask(in: .seconds(30)) {
                        answered.fail(ChannelError.connectTimeout(.seconds(30)))
                    }
                    do { return try await answered.futureResult.get().status } catch { return -1 }
                }
            }
            var answered = 0
            var stalled = 0
            for try await status in tasks {
                if status == 200 { answered += 1 } else { stalled += 1 }
            }
            // The discriminator: a request the *client leg* lost never becomes a
            // flow, while one the *upstream leg* lost is captured and then sits
            // there with no response. Counting both says which half to look at.
            let flows = await engine.recentFlows(limit: 200)
            let withResponse = flows.filter { $0.response != nil }.count
            #expect(stalled == 0, """
            \(stalled) of 40 stalled. captured flows=\(flows.count), of which answered=\(withResponse). \
            flows < 40 means the client leg dropped requests; flows == 40 with fewer answered \
            means the upstream leg did.
            """)
        }

        await engine.stopForTest()
    }
}
