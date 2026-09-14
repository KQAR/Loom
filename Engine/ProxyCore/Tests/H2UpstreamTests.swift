import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOSSL
import NIOTLS
import Synchronization
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
    private func forwarder(pool: UpstreamConnectionPool = UpstreamConnectionPool()) -> NIOStreamingForwarder {
        NIOStreamingForwarder(
            group: group,
            clientIdentities: ClientCertificateConfig(
                certificates: [], fileURL: nil, baseConfiguration: material.clientConfiguration
            ),
            pool: pool
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

    /// A field section too large for one HEADERS frame goes upstream over HTTP/1.1
    /// rather than failing to serialize.
    ///
    /// The defect this pins was reported from a real Android app and reproduced with
    /// no Loom code at all (`Tools/h2-frame-size-repro`): SwiftNIO's frame encoder
    /// emits no CONTINUATION frames, so a HEADERS payload past
    /// `SETTINGS_MAX_FRAME_SIZE` throws `NIOHTTP2Errors.UnableToSerializeFrame` — a
    /// *connection* error. Direct, and through a plain tunnelling proxy, the same
    /// request is answered 200, because real clients do send CONTINUATION. So the
    /// failure existed **only while Loom was in the path**, which is the one class of
    /// bug a debugging proxy must not introduce.
    ///
    /// The origin below offers only `h2`, so if Loom still asked for it the exchange
    /// would land on the h2 leg and the write would fail — the assertion is the round
    /// trip, not the recorded version.
    @Test func anOversizedFieldSectionFallsBackToHTTP1() async throws {
        let origin = try ALPNOrigin(material: material, offering: ["h2", "http/1.1"], group: group)
        defer { origin.stop() }

        // Base64-ish, so HPACK's Huffman coding cannot shrink it into the frame the
        // way a run of one character would.
        let attestation = String(
            (0 ..< 24_000).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".randomElement()! }
        )
        let result = try await forwarder().forwardStream(
            method: "GET", url: URL(string: "https://127.0.0.1:\(origin.port)/rpc")!,
            headers: [HeaderPair(name: "x-attestation", value: attestation)],
            body: .bytes(nil), origin: nil, clientProtocol: .http2
        ).collect()

        #expect(result.statusCode == 200, "this request is answered direct; it must be answered through Loom")
        #expect(result.httpVersion == "HTTP/1.1")
        #expect(origin.negotiatedProtocol != "h2",
                """
                h2 must not even be *offered*: ALPN is what decides which stack Loom \
                installs, so an accepted offer with an HTTP/1.1 pipeline behind it reads \
                HTTP/2 frames with an HTTP/1.1 parser — which is how this test first failed
                """)
    }

    /// The bytes need not be in a *header*. `:path` rides the same HEADERS block and
    /// is not one of the fields the caller passes, so a request whose weight is all
    /// query string read as tiny, went out over h2, and died the same way — an OAuth
    /// PAR `request` parameter or a `SAMLRequest` is exactly this shape.
    @Test func anOversizedQueryStringAlsoLeavesH2() async throws {
        let origin = try ALPNOrigin(material: material, offering: ["h2", "http/1.1"], group: group)
        defer { origin.stop() }

        let query = String(repeating: "q", count: 20_000)
        let result = try await forwarder().forwardStream(
            method: "GET", url: URL(string: "https://127.0.0.1:\(origin.port)/rpc?request=\(query)")!,
            headers: [], body: .bytes(nil), origin: nil, clientProtocol: .http2
        ).collect()

        #expect(result.statusCode == 200)
        #expect(origin.negotiatedProtocol != "h2",
                "the target is part of the field section; an estimate that ignores it is not a bound")
    }

    /// …and the downgrade says so, because "HTTP/1.1" on the flow is otherwise
    /// indistinguishable from an origin that declined `h2`.
    @Test func anOversizedFieldSectionMarksTheFlow() async throws {
        let origin = try ALPNOrigin(material: material, offering: ["h2", "http/1.1"], group: group)
        defer { origin.stop() }

        let big = String(repeating: "x", count: 20_000)
        let downgraded = try await forwarder().forwardStream(
            method: "GET", url: URL(string: "https://127.0.0.1:\(origin.port)/rpc")!,
            headers: [HeaderPair(name: "x-attestation", value: big)],
            body: .bytes(nil), origin: nil, clientProtocol: .http2
        ).collect()
        #expect(downgraded.transport?.upstreamProtocolDowngraded == true)

        let ordinary = try await forwarder().forwardStream(
            method: "GET", url: URL(string: "https://127.0.0.1:\(origin.port)/rpc")!,
            headers: [], body: .bytes(nil), origin: nil, clientProtocol: .http1
        ).collect()
        #expect(ordinary.transport?.upstreamProtocolDowngraded == nil,
                "an h1 client's leg was never downgraded; the key must not be there at all")
    }

    /// The estimate only ever guesses **high**. HPACK shrinks a field and never grows
    /// one, so a bound that read low would be the one that kills a connection —
    /// sending an exchange to HTTP/1.1 that would have fitted costs nothing.
    @Test func theHeaderEstimateIsAnUpperBound() {
        #expect(HTTP2HeaderBudget.estimatedBlockBytes([]) > 0,
                "the pseudo-header block and the fields writeRequest adds are not free")
        let one = HTTP2HeaderBudget.estimatedBlockBytes(
            [HeaderPair(name: "x", value: String(repeating: "a", count: 100))]
        )
        #expect(one > 101)
        // A cookie is re-split one field per crumb on the h2 leg, and each crumb
        // carries its own prefix — a bound that missed this would under-count exactly
        // the field that gets large.
        let crumbs = HTTP2HeaderBudget.estimatedBlockBytes(
            [HeaderPair(name: "cookie", value: (0 ..< 50).map { "k\($0)=v" }.joined(separator: "; "))]
        )
        let flat = HTTP2HeaderBudget.estimatedBlockBytes(
            [HeaderPair(name: "cookie", value: String(repeating: "z", count: 350))]
        )
        #expect(crumbs > flat, "50 fields cost more prefixes than one field of the same length")
    }

    /// `te: trailers` survives the h2 leg, because gRPC does not work without it.
    ///
    /// `TE` is hop-by-hop (RFC 9110 §7.6.1) and Loom dropped it on both legs. RFC
    /// 9113 §8.2.2 carves it out by name for HTTP/2 — a request *may* carry `te`
    /// when the value is exactly `trailers` — and the gRPC wire spec makes it
    /// mandatory.
    ///
    /// Measured against a real grpc C-core server (grpcio 1.84 — the transport behind
    /// C++, Python, Ruby, C#, PHP and Objective-C), same health-check RPC, raw HTTP/2
    /// framer so only this one field differs:
    ///
    ///     with    te: trailers → :status=200, grpc-status=0
    ///     without te: trailers → RST_STREAM INTERNAL_ERROR, no status, no response
    ///
    /// Its source says why: `MalformedRequest("Missing :te header")`. grpc-java only
    /// warns — and names the culprit, "some intermediate proxy may not support
    /// trailers" — while grpc-go does not check at all, which is why one
    /// implementation was not enough to answer this.
    @Test func theH2LegKeepsTETrailers() async throws {
        let origin = try ALPNOrigin(material: material, offering: ["h2"], group: group)
        defer { origin.stop() }

        _ = try await forwarder().forwardStream(
            method: "POST", url: URL(string: "https://127.0.0.1:\(origin.port)/rpc")!,
            headers: [HeaderPair(name: "te", value: "trailers"),
                      HeaderPair(name: "content-type", value: "application/grpc")],
            body: .bytes(Data()), origin: nil, clientProtocol: .http2
        ).collect()

        #expect(origin.teField == "trailers",
                "a C-core gRPC server answers RST_STREAM without this, and nothing says why")
    }

    /// Only the literal `trailers`, and that bound is not tidiness: RFC 9113 §8.2.2
    /// allows no other value, and `NIOHTTP2` enforces it with
    /// `forbiddenHeaderField` — so forwarding an h1 client's `te: gzip` would trade a
    /// stripped field for a killed connection.
    @Test func theH2LegDropsAnyOtherTEValue() async throws {
        let origin = try ALPNOrigin(material: material, offering: ["h2"], group: group)
        defer { origin.stop() }

        let result = try await forwarder().forwardStream(
            method: "POST", url: URL(string: "https://127.0.0.1:\(origin.port)/rpc")!,
            headers: [HeaderPair(name: "te", value: "gzip, trailers")],
            body: .bytes(Data()), origin: nil, clientProtocol: .http2
        ).collect()

        #expect(result.statusCode == 200, "the exchange must survive, not be refused by the codec")
        #expect(origin.teField == nil)
    }

    /// …and an HTTP/1.1 leg still drops it, because there `TE` is exactly the
    /// hop-by-hop field RFC 9110 §7.6.1 says it is — the carve-out is HTTP/2's alone.
    @Test func theHTTP1LegStillDropsTE() async throws {
        let origin = try ALPNOrigin(material: material, offering: ["http/1.1"], group: group)
        defer { origin.stop() }

        _ = try await forwarder().forwardStream(
            method: "POST", url: URL(string: "https://127.0.0.1:\(origin.port)/rpc")!,
            headers: [HeaderPair(name: "te", value: "trailers")],
            body: .bytes(Data()), origin: nil, clientProtocol: .http1
        ).collect()

        #expect(origin.teField == nil)
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

    // MARK: - Idle expiry and liveness (0.0.28)

    /// A shared h2 connection is expired once it goes quiet for `idleTimeout`, exactly
    /// like a parked h1 one. Before this, an h2 connection sat in the pool with no
    /// expiry at all — the 37-minute-idle socket that cost five requests 33–51 s each.
    @Test func anIdleH2ConnectionIsExpiredAndTheNextRequestReconnects() async throws {
        let origin = try ALPNOrigin(material: material, offering: ["h2"], group: group)
        defer { origin.stop() }
        let pool = UpstreamConnectionPool(limits: .init(idleTimeout: .milliseconds(200)))
        let forwarder = self.forwarder(pool: pool)
        let url = URL(string: "https://127.0.0.1:\(origin.port)/rpc")!

        let first = try await forwarder.forwardStream(
            method: "GET", url: url, headers: [], body: .bytes(nil), origin: nil, clientProtocol: .http2
        ).collect()
        #expect(first.statusCode == 200)
        #expect(origin.connectionCount == 1)

        // Sit past the idle window with no traffic, so the re-arming watch expires it.
        try await Task.sleep(for: .milliseconds(700))
        #expect(pool.statistics.idleExpiries >= 1, "the idle h2 connection must be reaped, not kept forever")

        let second = try await forwarder.forwardStream(
            method: "GET", url: url, headers: [], body: .bytes(nil), origin: nil, clientProtocol: .http2
        ).collect()
        #expect(second.statusCode == 200)
        #expect(origin.connectionCount == 2, "the expired connection is gone, so the next request opens a fresh one")
    }

    /// A connection idle past `livenessProbeAfterIdle` is PINGed before it is handed
    /// out. Against a live origin the ACK comes back, so the connection is reused —
    /// the probe adds a round trip, not a reconnect, on the healthy path.
    @Test func aStillLiveIdleH2ConnectionPassesItsPreUseProbeAndIsReused() async throws {
        let origin = try ALPNOrigin(material: material, offering: ["h2"], group: group)
        defer { origin.stop() }
        let pool = UpstreamConnectionPool(limits: .init(
            idleTimeout: .seconds(45), livenessProbeAfterIdle: .milliseconds(1)
        ))
        let forwarder = self.forwarder(pool: pool)
        let url = URL(string: "https://127.0.0.1:\(origin.port)/rpc")!

        _ = try await forwarder.forwardStream(
            method: "GET", url: url, headers: [], body: .bytes(nil), origin: nil, clientProtocol: .http2
        ).collect()
        #expect(origin.connectionCount == 1)

        // Long enough to cross the probe threshold, nowhere near the idle timeout.
        try await Task.sleep(for: .milliseconds(50))

        let second = try await forwarder.forwardStream(
            method: "GET", url: url, headers: [], body: .bytes(nil), origin: nil, clientProtocol: .http2
        ).collect()
        #expect(second.statusCode == 200)
        #expect(origin.connectionCount == 1, "a probe that ACKs reuses the socket; it does not reconnect")
        #expect(pool.statistics.livenessProbeFailures == 0, "a live origin answers its PING")
        #expect(pool.statistics.deadReuseDetected == 0)
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
    var teField: String? { observed.te }
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

/// What the origin saw. State behind a lock rather than plain vars: the accepting
/// loop writes it while the test's task reads it.
///
/// A `Mutex`, like every other holder in this repo since the floor rose to macOS 15
/// — so there is no mutable stored property left for an `@unchecked` to vouch for
/// and the conformance is plain `Sendable`.
private final class ALPNObservations: Sendable {
    private struct State {
        var negotiatedName: String?
        var connectionTotal = 0
        var cookieFields: [String] = []
        var transferEncodingField: String?
        var teField: String?
        var bodyText = ""
    }

    private let state = Mutex(State())

    var negotiated: String? { state.withLock { $0.negotiatedName } }
    var connections: Int { state.withLock { $0.connectionTotal } }
    var cookies: [String] { state.withLock { $0.cookieFields } }
    var transferEncoding: String? { state.withLock { $0.transferEncodingField } }
    var te: String? { state.withLock { $0.teField } }
    var body: String { state.withLock { $0.bodyText } }

    func record(_ name: String) { state.withLock { $0.negotiatedName = name } }
    func countConnection() { state.withLock { $0.connectionTotal += 1 } }

    func record(head: HTTPRequestHead) {
        // `headers[name]`, not `canonicalForm`: the latter splits list-typed fields
        // on commas, which would report a different number of fields than were
        // actually sent — and the number is the whole assertion here.
        record(cookies: head.headers["cookie"], transferEncoding: head.headers.first(name: "transfer-encoding"),
               te: head.headers.first(name: "te"))
    }

    func record(cookies: [String], transferEncoding: String?, te: String? = nil) {
        state.withLock {
            $0.teField = te
            $0.cookieFields = cookies
            $0.transferEncodingField = transferEncoding
            $0.bodyText = ""
        }
    }

    func append(body chunk: String) { state.withLock { $0.bodyText += chunk } }
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
                transferEncoding: headers.headers.first(name: "transfer-encoding"),
                te: headers.headers.first(name: "te")
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
