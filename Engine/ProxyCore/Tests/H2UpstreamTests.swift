import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOSSL
import NIOTLS
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// The upstream leg matches the protocol the client spoke, instead of always
/// re-originating as HTTP/1.1.
///
/// What the old behaviour cost, in order of how loudly it failed: a gRPC origin
/// refused the exchange outright (h2-only, and an HTTP/1.1 request to one is not a
/// request at all); response trailers had to survive a translation they need not have
/// gone through; and `CapturedResponse.httpVersion` read "HTTP/1.1" for traffic the
/// operator was watching precisely because it was h2.
///
/// The `cookie` field travels as one merged field through the model — that is the
/// canonical message, not a concession — and is re-split per pair when the request
/// goes out over h2 (`theH2LegSplitsCookieCrumbsBack` below). What that does **not**
/// fix, stated so it isn't assumed: the h1 leg still sends one line, because RFC 6265
/// §5.4 allows exactly one, so the oversized-single-line risk `MITMPipeline` §
/// maxHeaderListSize records stays open there.
///
/// Against a **real** ALPN-negotiating origin, because the thing under test is the
/// negotiation: a stub cannot decline an offer.
@Suite("HTTP/2 upstream", .timeLimit(.minutes(1)))
final class H2UpstreamTests {
    private let group: MultiThreadedEventLoopGroup
    private let material: TLSMaterial

    init() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        material = try TLSMaterial.make()
    }

    deinit { shutdownBlocking(group) }

    /// The forwarder has to trust the throwaway CA, which it does through the same
    /// seam the mutual-TLS tests use — and which now also decides whether `h2` is
    /// offered, so this exercises the production ALPN path rather than a parallel one.
    private func forwarder() -> NIOStreamingForwarder {
        NIOStreamingForwarder(
            group: group,
            clientIdentities: ClientCertificateConfig(
                certificates: [], fileURL: nil, baseConfiguration: material.clientConfiguration
            )
        )
    }

    @Test func anH2ClientGetsAnH2UpstreamConnection() async throws {
        let origin = try ALPNOrigin(material: material, offering: ["h2", "http/1.1"], group: group)
        defer { origin.stop() }

        let result = try await forwarder().forwardStream(
            method: "GET", url: URL(string: "https://127.0.0.1:\(origin.port)/rpc")!,
            headers: [], body: .bytes(nil), origin: nil, clientProtocol: .http2
        ).collect()

        #expect(result.statusCode == 200)
        #expect(result.httpVersion == "HTTP/2",
                "the h2↔h1 codec hands over an HTTP/1.1 head, so this has to be stated by the stack, not read off it")
        #expect(origin.negotiatedProtocol == "h2")
        #expect(result.trailers?.first { $0.name == "grpc-status" }?.value == "0",
                "trailers ride an h2 leg natively — no chunked re-framing in sight")
    }

    /// The other half of the rule, and the one that keeps Loom out of the way: an
    /// HTTP/1.1 client must not have its traffic quietly upgraded. A proxy that
    /// negotiated h2 on its own would change which protocol the origin sees for
    /// traffic nobody asked it to change, and every h2-specific origin behaviour
    /// after that would be Loom's to explain.
    @Test func anHTTP1ClientIsNotUpgraded() async throws {
        let origin = try ALPNOrigin(material: material, offering: ["h2", "http/1.1"], group: group)
        defer { origin.stop() }

        let result = try await forwarder().forwardStream(
            method: "GET", url: URL(string: "https://127.0.0.1:\(origin.port)/rpc")!,
            headers: [], body: .bytes(nil), origin: nil, clientProtocol: .http1
        ).collect()

        #expect(result.statusCode == 200)
        #expect(result.httpVersion == "HTTP/1.1")
        #expect(origin.negotiatedProtocol != "h2",
                "the origin offers h2; Loom must not have asked for it on an h1 client's behalf")
    }

    /// An origin is entitled to decline. `h2` is an offer, not a demand, and the
    /// answer decides the pipeline — which is why both stacks are installed from the
    /// ALPN callback rather than chosen before connecting.
    @Test func anOriginThatDeclinesH2GetsTheHTTP1Stack() async throws {
        let origin = try ALPNOrigin(material: material, offering: ["http/1.1"], group: group)
        defer { origin.stop() }

        let result = try await forwarder().forwardStream(
            method: "GET", url: URL(string: "https://127.0.0.1:\(origin.port)/rpc")!,
            headers: [], body: .bytes(nil), origin: nil, clientProtocol: .http2
        ).collect()

        #expect(result.statusCode == 200)
        #expect(result.httpVersion == "HTTP/1.1")
        #expect(result.trailers?.first { $0.name == "grpc-status" }?.value == "0",
                "the h1 leg still has to carry the trailer section — that is what the chunked framing is for")
    }

    /// The h2 leg re-splits the canonical `cookie` field into one crumb per pair.
    ///
    /// Not cosmetic: HPACK's dynamic table defaults to 4096 bytes and charges each
    /// field `name + value + 32`, so a site with kilobytes of cookies produces a
    /// merged field that never fits and is re-sent as a literal on every request,
    /// where the crumbs are each indexed once and cost about a byte thereafter.
    ///
    /// The *message* is unchanged — an h2 server concatenates before handing the
    /// request to an application (RFC 9113 §8.2.3), which is why the origin below can
    /// assert on both forms at once.
    @Test func theH2LegSplitsCookieCrumbsBack() async throws {
        let origin = try ALPNOrigin(material: material, offering: ["h2"], group: group)
        defer { origin.stop() }

        _ = try await forwarder().forwardStream(
            method: "GET", url: URL(string: "https://127.0.0.1:\(origin.port)/rpc")!,
            headers: [HeaderPair(name: "cookie", value: "a=1; user_session=abc; z=9")],
            body: .bytes(nil), origin: nil, clientProtocol: .http2
        ).collect()

        // What the h2↔h1 codec hands the origin's handler: NIOHTTP2 does not
        // concatenate, so the crumbs arrive as separate fields — which is the proof
        // they were sent as separate fields.
        #expect(origin.cookieFields == ["a=1", "user_session=abc", "z=9"])
    }

    /// An h1 leg gets the opposite, and must: RFC 6265 §5.4 allows exactly one
    /// `Cookie` field, and sending crumbs is the bug that logged people out.
    @Test func theHTTP1LegKeepsOneCookieField() async throws {
        let origin = try ALPNOrigin(material: material, offering: ["http/1.1"], group: group)
        defer { origin.stop() }

        _ = try await forwarder().forwardStream(
            method: "GET", url: URL(string: "https://127.0.0.1:\(origin.port)/rpc")!,
            headers: [HeaderPair(name: "cookie", value: "a=1; user_session=abc; z=9")],
            body: .bytes(nil), origin: nil, clientProtocol: .http2
        ).collect()

        #expect(origin.cookieFields == ["a=1; user_session=abc; z=9"])
    }

    /// An unknown-length body round-trips over an h2 leg, carrying no framing header.
    ///
    /// **This test cannot fail on the framing half, and that is worth stating rather
    /// than dressing up.** `Transfer-Encoding` is connection-specific — RFC 9113
    /// §8.2.2 says a request MUST NOT contain one and a receiver MUST treat it as
    /// malformed — and the forwarder now skips it for an h2 leg. But it was measured:
    /// with that skip removed the assertion below still passes, because
    /// `HTTP2FramePayloadToHTTP1ClientCodec` strips connection-specific fields on the
    /// way out. So Loom's own guard is belt-and-braces (do not emit a field the
    /// protocol forbids, rather than rely on a library to clean up after us) and only
    /// the round trip is really pinned here. If NIOHTTP2 ever stops stripping, this
    /// starts failing — which is the useful half.
    @Test func anUnknownLengthBodyRoundTripsOverH2() async throws {
        let origin = try ALPNOrigin(material: material, offering: ["h2"], group: group)
        defer { origin.stop() }

        // A streamed body whose client declared no Content-Length — the h1 leg would
        // re-frame this as chunked.
        let bridge = RequestBodyBridge(capture: RequestBodyCapture())
        bridge.yield(Data("payload".utf8))
        bridge.finish()

        let result = try await forwarder().forwardStream(
            method: "POST", url: URL(string: "https://127.0.0.1:\(origin.port)/rpc")!,
            headers: [], body: .stream(bridge.chunks, contentLength: nil),
            origin: nil, clientProtocol: .http2
        ).collect()

        #expect(result.statusCode == 200, "a malformed request would have been reset, not answered")
        #expect(origin.transferEncoding == nil)
        #expect(origin.requestBody == "payload")
    }

    /// One connection, many streams. The h1 pool takes a connection out on lease and
    /// puts it back on release; an h2 connection is shared instead, and getting that
    /// wrong is not a slow path but a wrong one — a second exchange would be handed a
    /// socket the first is still using as though it were idle.
    @Test func concurrentH2ExchangesShareOneConnection() async throws {
        let origin = try ALPNOrigin(material: material, offering: ["h2"], group: group)
        defer { origin.stop() }
        let forwarder = self.forwarder()
        let port = origin.port

        try await withThrowingTaskGroup(of: Int.self) { tasks in
            for index in 0 ..< 6 {
                tasks.addTask { [forwarder] in
                    let result = try await forwarder.forwardStream(
                        method: "GET", url: URL(string: "https://127.0.0.1:\(port)/rpc/\(index)")!,
                        headers: [], body: .bytes(nil), origin: nil, clientProtocol: .http2
                    ).collect()
                    return result.statusCode
                }
            }
            for try await status in tasks { #expect(status == 200) }
        }

        #expect(origin.connectionCount == 1,
                "six exchanges over one h2 connection; more than one means the sharing broke")
    }
}

// MARK: - Test doubles

/// A TLS origin that negotiates ALPN from a fixed offer list and answers over
/// whichever protocol was chosen — `200` with a body and a `grpc-status: 0` trailer,
/// so the trailer path is exercised on both legs.
private final class ALPNOrigin {
    let port: Int
    private let channel: Channel
    private let observed = ALPNObservations()

    var negotiatedProtocol: String? { observed.negotiated }
    var connectionCount: Int { observed.connections }
    /// Every `cookie` field as it arrived — NIOHTTP2 does no concatenating of its
    /// own, so on an h2 leg this is literally how many fields were sent.
    var cookieFields: [String] { observed.cookies }
    var transferEncoding: String? { observed.transferEncoding }
    var requestBody: String { observed.body }

    init(material: TLSMaterial, offering: [String], group: EventLoopGroup) throws {
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: try NIOSSLCertificate.fromPEMBytes(Array(material.serverCertPEM.utf8))
                .map { .certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(material.serverKeyPEM.utf8), format: .pem))
        )
        configuration.applicationProtocols = offering
        let context = try NIOSSLContext(configuration: configuration)
        let observed = self.observed

        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                observed.countConnection()
                return channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    try sync.addHandler(NIOSSLServerHandler(context: context))
                    try sync.addHandler(ApplicationProtocolNegotiationHandler { result in
                        if case let .negotiated(name) = result { observed.record(name) }
                        if case .negotiated("h2") = result {
                            return channel.configureHTTP2Pipeline(mode: .server) { stream in
                                stream.eventLoop.makeCompletedFuture {
                                    let sync = stream.pipeline.syncOperations
                                    // **Before** the codec, on purpose. The h2↔h1
                                    // server codec synthesizes `transfer-encoding:
                                    // chunked` for a request with no content-length,
                                    // so reading the converted h1 head would measure
                                    // the codec's invention rather than the bytes
                                    // Loom put on the wire — which is the whole
                                    // assertion.
                                    try sync.addHandler(HeadersFrameObserver(observed: observed))
                                    try sync.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())
                                    try sync.addHandler(TrailingResponder(observed: observed, recordsHead: false))
                                }
                            }.map { _ in }
                        }
                        return channel.pipeline.configureHTTPServerPipeline().flatMap {
                            channel.eventLoop.makeCompletedFuture {
                                try channel.pipeline.syncOperations.addHandler(
                                    TrailingResponder(observed: observed, recordsHead: true)
                                )
                            }
                        }
                    })
                }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
        port = channel.localAddress?.port ?? 0
    }

    func stop() { try? channel.close().wait() }
}

/// What the origin saw. A class with a lock rather than plain vars: the accepting
/// loop writes it while the test's task reads it.
private final class ALPNObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var negotiatedName: String?
    private var connectionTotal = 0
    private var cookieFields: [String] = []
    private var transferEncodingField: String?
    private var bodyText = ""

    var negotiated: String? { lock.withLock { negotiatedName } }
    var connections: Int { lock.withLock { connectionTotal } }
    var cookies: [String] { lock.withLock { cookieFields } }
    var transferEncoding: String? { lock.withLock { transferEncodingField } }
    var body: String { lock.withLock { bodyText } }

    func record(_ name: String) { lock.withLock { negotiatedName = name } }
    func countConnection() { lock.withLock { connectionTotal += 1 } }

    func record(head: HTTPRequestHead) {
        // `headers[name]`, not `canonicalForm`: the latter splits list-typed fields
        // on commas, which would report a different number of fields than were
        // actually sent — and the number is the whole assertion here.
        record(cookies: head.headers["cookie"], transferEncoding: head.headers.first(name: "transfer-encoding"))
    }

    func record(cookies: [String], transferEncoding: String?) {
        lock.withLock {
            cookieFields = cookies
            transferEncodingField = transferEncoding
            bodyText = ""
        }
    }

    func append(body chunk: String) { lock.withLock { bodyText += chunk } }
}

/// Reads the HEADERS frame as it arrived, before any h2↔h1 conversion — the only
/// place the fields Loom actually encoded still exist unaltered.
private final class HeadersFrameObserver: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias InboundOut = HTTP2Frame.FramePayload

    private let observed: ALPNObservations

    init(observed: ALPNObservations) { self.observed = observed }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case let .headers(headers) = unwrapInboundIn(data) {
            observed.record(
                cookies: headers.headers[canonicalForm: "cookie"].map { String($0) },
                transferEncoding: headers.headers.first(name: "transfer-encoding")
            )
        }
        context.fireChannelRead(data)
    }
}

/// Answers every request with a body and a trailer section, whichever protocol it
/// arrived on — the h2↔h1 codecs make both look the same from here, which is the
/// property that lets one responder serve both stacks.
private final class TrailingResponder: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let observed: ALPNObservations
    /// False on the h2 path, where `HeadersFrameObserver` has already recorded the
    /// real fields and the converted h1 head would overwrite them with the codec's.
    private let recordsHead: Bool

    init(observed: ALPNObservations, recordsHead: Bool) {
        self.observed = observed
        self.recordsHead = recordsHead
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            if recordsHead { observed.record(head: head) }
            return
        case var .body(buffer):
            observed.append(body: buffer.readString(length: buffer.readableBytes) ?? "")
            return
        case .end:
            break
        }
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/grpc")
        // Chunked so the h1 leg has somewhere to put the trailer section; the h2 leg
        // ignores this and sends a HEADERS frame after the DATA.
        headers.add(name: "transfer-encoding", value: "chunked")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: 2)
        buffer.writeString("ok")
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        var trailers = HTTPHeaders()
        trailers.add(name: "grpc-status", value: "0")
        context.writeAndFlush(wrapOutboundOut(.end(trailers)), promise: nil)
    }
}
