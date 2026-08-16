import Foundation
import Synchronization
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// The upstream pool, against a real local NIO HTTP/1.1 server that counts the
/// connections it accepts.
///
/// The counter is the whole point of this suite: every other property here
/// (correct bodies, correct headers) was already true when each request opened its
/// own socket, so a test that only checked responses would have passed against the
/// unpooled forwarder this replaced.
@Suite("Upstream connection pool", .timeLimit(.minutes(1)))
final class UpstreamConnectionPoolTests {
    private let group: MultiThreadedEventLoopGroup
    private let server: Channel
    private let accepts: AcceptCounter
    /// Captured once so the closures below never have to reach through `self`.
    private let origin: String

    init() throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 3)
        let accepts = AcceptCounter()
        self.accepts = accepts
        server = try Self.startServer(group: group, accepts: accepts)
        origin = "http://127.0.0.1:\(server.localAddress!.port!)"
    }

    deinit {
        try? server.close().wait()
        shutdownBlocking(group)
    }

    static func startServer(group: EventLoopGroup, accepts: AcceptCounter) throws -> Channel {
        try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                accepts.increment()
                return channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    try sync.configureHTTPServerPipeline()
                    try sync.addHandler(PoolTestResponder())
                }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
    }

    private var acceptCount: Int { accepts.value }
    private func url(_ path: String) -> URL { URL(string: origin + path)! }

    // MARK: - The reuse itself

    @Test func sequentialRequests_shareOneConnection() async throws {
        let forwarder = NIOStreamingForwarder(group: group)
        for index in 0..<5 {
            let result = try await forwarder.forward(
                method: "GET", url: url("/ok?i=\(index)"), headers: [], body: nil
            )
            #expect(result.statusCode == 200)
            #expect(String(decoding: result.body, as: UTF8.self) == "ok")
        }
        #expect(acceptCount == 1, "five keep-alive requests to one origin must cost one connection")
    }

    @Test func poolIsPerOrigin_soAPortChangeDoesNotReuse() async throws {
        // A second server on its own port: same host, different origin, and the key
        // has to keep them apart or a request lands on the wrong server entirely.
        let otherAccepts = AcceptCounter()
        let other = try Self.startServer(group: group, accepts: otherAccepts)
        defer { other.close(promise: nil) }

        let forwarder = NIOStreamingForwarder(group: group)
        _ = try await forwarder.forward(method: "GET", url: url("/ok"), headers: [], body: nil)
        _ = try await forwarder.forward(
            method: "GET", url: URL(string: "http://127.0.0.1:\(other.localAddress!.port!)/ok")!,
            headers: [], body: nil
        )
        _ = try await forwarder.forward(method: "GET", url: url("/ok"), headers: [], body: nil)

        #expect(acceptCount == 1)
        #expect(otherAccepts.value == 1)
    }

    @Test func concurrentRequests_doNotShareOneConnection() async throws {
        // HTTP/1.1 has no multiplexing here, so three overlapping exchanges need
        // three sockets — a pool that handed the same one out twice would interleave
        // two requests on one connection and corrupt both.
        let forwarder = NIOStreamingForwarder(group: group)
        let urls = (0..<3).map { url("/slow?i=\($0)") }
        try await withThrowingTaskGroup(of: String.self) { tasks in
            for target in urls {
                tasks.addTask {
                    let result = try await forwarder.forward(
                        method: "GET", url: target, headers: [], body: nil
                    )
                    return String(decoding: result.body, as: UTF8.self)
                }
            }
            var bodies: [String] = []
            for try await body in tasks { bodies.append(body) }
            #expect(bodies == ["slow", "slow", "slow"])
        }
        #expect(acceptCount == 3, "overlapping exchanges must each get their own connection")
    }

    @Test func bodiesStayCorrectAcrossAReusedConnection() async throws {
        // The failure this guards against is not "slow" but "wrong": a reused
        // connection whose decoder or decompressor carried state would answer the
        // second request with a mangled version of the first.
        let forwarder = NIOStreamingForwarder(group: group)
        let first = try await forwarder.forward(
            method: "POST", url: url("/echo"), headers: [], body: Data("alpha".utf8)
        )
        let second = try await forwarder.forward(
            method: "POST", url: url("/echo"), headers: [], body: Data("bravo-and-longer".utf8)
        )
        #expect(String(decoding: first.body, as: UTF8.self) == "alpha")
        #expect(String(decoding: second.body, as: UTF8.self) == "bravo-and-longer")
        #expect(acceptCount == 1)
    }

    @Test func compressedAndPlainResponses_interleaveOnOneConnection() async throws {
        // `NIOHTTPResponseDecompressor` builds its decoder per response head and
        // drops it on end, which is what makes it safe to keep across a pooled
        // connection — pinned here because a stale decoder would surface as a
        // corrupt body several requests later, nowhere near the cause.
        let forwarder = NIOStreamingForwarder(group: group)
        for _ in 0..<2 {
            let compressed = try await forwarder.forward(method: "GET", url: url("/deflate"), headers: [], body: nil)
            #expect(String(decoding: compressed.body, as: UTF8.self) == PoolTestResponder.deflatedPlaintext)
            let plain = try await forwarder.forward(method: "GET", url: url("/ok"), headers: [], body: nil)
            #expect(String(decoding: plain.body, as: UTF8.self) == "ok")
        }
        #expect(acceptCount == 1)
    }

    // MARK: - What must not be pooled

    @Test func connectionCloseResponse_isNotReused() async throws {
        let forwarder = NIOStreamingForwarder(group: group)
        for _ in 0..<3 {
            _ = try await forwarder.forward(method: "GET", url: url("/close"), headers: [], body: nil)
        }
        #expect(acceptCount == 3, "a `Connection: close` response ends the connection with it")
    }

    @Test func closeDelimitedResponse_isNotReused() async throws {
        // No Content-Length and no chunked framing: the body ends when the socket
        // does, so there is nothing left to pool. Parking one of these would hand
        // the next request a socket already closing.
        let forwarder = NIOStreamingForwarder(group: group)
        for _ in 0..<3 {
            let result = try await forwarder.forward(method: "GET", url: url("/nolength"), headers: [], body: nil)
            #expect(String(decoding: result.body, as: UTF8.self) == "unframed")
        }
        #expect(acceptCount == 3)
    }

    @Test func streamedRequestBody_doesNotLeaseButDoesRelease() async throws {
        // A live client stream is consumed exactly once, so there is no second copy
        // to re-send if a leased connection turns out to be stale — such a request
        // opens its own connection. It must still hand that connection back.
        let forwarder = NIOStreamingForwarder(group: group)
        _ = try await forwarder.forward(method: "GET", url: url("/ok"), headers: [], body: nil)
        #expect(acceptCount == 1)

        let bridge = RequestBodyBridge(capture: RequestBodyCapture())
        bridge.yield(Data("streamed".utf8))
        bridge.finish()
        var streamedBody = Data()
        for try await event in forwarder.forwardStream(
            method: "POST", url: url("/echo"), headers: [],
            body: .stream(bridge.chunks, contentLength: 8)
        ) {
            if case let .body(chunk) = event { streamedBody.append(chunk) }
        }
        #expect(String(decoding: streamedBody, as: UTF8.self) == "streamed")
        #expect(acceptCount == 2, "a streamed body declines the parked connection")

        _ = try await forwarder.forward(method: "GET", url: url("/ok"), headers: [], body: nil)
        #expect(acceptCount == 2, "...but releases its own, so the next request reuses it")
    }

    // MARK: - Staleness

    @Test func originClosingAParkedConnection_neverFailsTheNextRequest() async throws {
        // `/reap` answers normally — keep-alive, Content-Length, everything a
        // poolable response has — and then drops the socket, which is what a real
        // origin's idle reaper does. Whether the FIN is seen while the connection is
        // parked (evicted) or after it has been leased (retried on a fresh socket)
        // is a race by nature, so this asserts the contract that holds either way:
        // no request fails. Twenty rounds is what makes the leased-then-dead branch
        // likely to be exercised rather than merely possible.
        let forwarder = NIOStreamingForwarder(group: group)
        for index in 0..<20 {
            let result = try await forwarder.forward(
                method: "GET", url: url("/reap?i=\(index)"), headers: [], body: nil
            )
            #expect(result.statusCode == 200)
            #expect(String(decoding: result.body, as: UTF8.self) == "reaped")
        }
    }

    // MARK: - Bounds and lifecycle

    @Test func idleConnectionsAreCappedPerOrigin() async throws {
        let pool = UpstreamConnectionPool(limits: .init(idlePerKey: 2, totalIdle: 8, idleTimeout: .seconds(45)))
        let forwarder = NIOStreamingForwarder(group: group, pool: pool)
        let urls = (0..<5).map { url("/slow?i=\($0)") }
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            for target in urls {
                tasks.addTask {
                    _ = try await forwarder.forward(method: "GET", url: target, headers: [], body: nil)
                }
            }
            try await tasks.waitForAll()
        }
        #expect(acceptCount == 5, "the burst still runs at full width")
        #expect(pool.idleCount <= 2, "only the cap is parked; the rest are closed on release")
    }

    @Test func drain_closesParkedConnections() async throws {
        let pool = UpstreamConnectionPool()
        let forwarder = NIOStreamingForwarder(group: group, pool: pool)
        _ = try await forwarder.forward(method: "GET", url: url("/ok"), headers: [], body: nil)
        #expect(pool.idleCount == 1)

        pool.drain()
        #expect(pool.idleCount == 0)

        // Not terminal: the pool works again afterwards, which is what lets the
        // proxy's off switch drain it without breaking the on switch.
        _ = try await forwarder.forward(method: "GET", url: url("/ok"), headers: [], body: nil)
        #expect(acceptCount == 2)
        #expect(pool.idleCount == 1)
    }

    @Test func aDisabledPool_keepsTheOldOneConnectionPerRequestShape() async throws {
        let forwarder = NIOStreamingForwarder(group: group, pool: .disabled)
        for _ in 0..<3 {
            _ = try await forwarder.forward(method: "GET", url: url("/ok"), headers: [], body: nil)
        }
        #expect(acceptCount == 3)
    }

    // MARK: - Interim responses

    @Test func aHundredContinueDoesNotCompleteTheExchange_orPoisonThePool() async throws {
        // RFC 9110 §15.2: a 1xx is interim, not the response. The decoder delivers
        // it as a complete head+end message, and treating that end as *the* end
        // released the connection while the final response was still on the wire —
        // the worst schedule then hands the previous request's response to the
        // next request. The raw server below speaks the exact byte sequence.
        let group = self.group
        let interimServer = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(RawInterimResponder())
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { interimServer.close(promise: nil) }
        let interimPort = interimServer.localAddress!.port!

        let pool = UpstreamConnectionPool()
        let forwarder = NIOStreamingForwarder(group: group, pool: pool)

        let first = try await forwarder.forward(
            method: "POST", url: URL(string: "http://127.0.0.1:\(interimPort)/upload")!,
            headers: [HeaderPair(name: "Expect", value: "100-continue")], body: Data("payload".utf8)
        )
        #expect(first.statusCode == 200, "the interim head must be swallowed, never delivered as the response")
        #expect(String(decoding: first.body, as: UTF8.self) == "first")

        // The second exchange is the actual assertion: on the poisoned pool it
        // received the *first* request's dangling 200.
        let second = try await forwarder.forward(
            method: "POST", url: URL(string: "http://127.0.0.1:\(interimPort)/upload")!,
            headers: [HeaderPair(name: "Expect", value: "100-continue")], body: Data("payload".utf8)
        )
        #expect(String(decoding: second.body, as: UTF8.self) == "second",
                "a response crossing exchanges is the failure the interim fix exists to prevent")
    }

    // MARK: - Retry discipline

    /// The retry decision, decided on its own rather than through twenty rounds of
    /// a socket race.
    ///
    /// `aStalePoolNeverFailsAPost_whoseWriteNeverLanded` below drives the real
    /// thing, and it is a coin flip per round by construction — which is what made
    /// it fail intermittently in CI and what made the underlying rule hard to see.
    /// These pin the rule itself, so a change to it fails deterministically here and
    /// the socket test stays the end-to-end check rather than the specification.
    @Test func aReapedPooledConnection_letsANonIdempotentRequestRetry() {
        // The shape the old rule got wrong: the flush *succeeded* (into the send
        // buffer of a socket the peer had already closed) and the connection then
        // died. `requestWritten` reads true for a request no origin ever saw.
        let reset = UpstreamAttemptFailure(
            underlying: IOError(errnoCode: ECONNRESET, reason: "read"),
            didYield: false, requestWritten: true
        )
        #expect(NIOStreamingForwarder.mayRetry(method: "POST", after: reset))
        #expect(NIOStreamingForwarder.mayRetry(method: "PATCH", after: reset))

        let closed = UpstreamAttemptFailure(
            underlying: ForwarderError.connectionClosed, didYield: false, requestWritten: true
        )
        #expect(NIOStreamingForwarder.mayRetry(method: "POST", after: closed))
    }

    /// The half that must not move. A failure that is *not* the transport going
    /// away can follow an origin having read and acted on the request, so a
    /// non-idempotent method is still not re-run.
    @Test func aNonTeardownFailure_stillDoesNotRerunAPost() {
        struct DecoderGaveUp: Error {}
        let applicationLevel = UpstreamAttemptFailure(
            underlying: DecoderGaveUp(), didYield: false, requestWritten: true
        )
        #expect(!NIOStreamingForwarder.mayRetry(method: "POST", after: applicationLevel))
        // An idempotent method is unaffected either way — repeating it re-asserts
        // the same state, which is what the RFC's set means.
        #expect(NIOStreamingForwarder.mayRetry(method: "GET", after: applicationLevel))
        // And a request whose flush never landed is still retryable whatever killed
        // it: nothing can have been applied.
        #expect(NIOStreamingForwarder.mayRetry(
            method: "POST",
            after: UpstreamAttemptFailure(underlying: DecoderGaveUp(), didYield: false, requestWritten: false)
        ))
    }

    @Test func isIdempotent_isRFC9110sSet() {
        for method in ["GET", "HEAD", "PUT", "DELETE", "OPTIONS", "TRACE", "get"] {
            #expect(NIOStreamingForwarder.isIdempotent(method), Comment(rawValue: method))
        }
        for method in ["POST", "PATCH", "QUERY", "LOCK"] {
            #expect(!NIOStreamingForwarder.isIdempotent(method), Comment(rawValue: method))
        }
    }

    @Test func aStalePoolNeverFailsAPost_whoseWriteNeverLanded() async throws {
        // The idempotency gate must not regress the stale-lease fix for POST-heavy
        // clients: every round here succeeds.
        //
        // This comment used to say the flush *fails* against a FIN'd socket, and
        // that the retry was therefore allowed under RFC 9110 §9.2.2's "never
        // reached the origin" branch. **That was wrong, and it is why this test
        // failed intermittently in CI rather than never.** A write to a socket
        // whose peer has closed succeeds — it lands in this host's send buffer,
        // FIN having ended only the peer→us direction — and the RST arrives later,
        // on the read. So roughly half these rounds produce `requestWritten == true`
        // for a request no origin ever saw, and under the old rule they failed.
        //
        // The gate reads the *failure* now, not the write (`mayRetry`), which is
        // what makes this deterministic. What it still forbids is re-running a POST
        // that died of something other than the transport going away — pinned in
        // `aNonTeardownFailure_stillDoesNotRerunAPost`, since no local server can
        // stage that honestly.
        let forwarder = NIOStreamingForwarder(group: group)
        for index in 0..<20 {
            let result = try await forwarder.forward(
                method: "POST", url: url("/reap?i=\(index)"), headers: [], body: Data("p".utf8)
            )
            #expect(result.statusCode == 200)
        }
    }

    // MARK: - The slot's failure holding

    @Test func aFailureBeforeArm_isHeldAndFailsTheArmWithItsOwnWords() {
        // A fresh connection's TLS handshake can run to failure before the
        // exchange arms. Dropping that error and reconstructing `connectionClosed`
        // from `isActive` lost the alert — and with it the `UpstreamTLSError`
        // naming which identity Loom presented.
        struct HandshakeStory: Error {}
        let slot = UpstreamExchangeSlot()
        slot.fail(HandshakeStory())

        let outcome = Mutex<Result<UpstreamAttemptEnd, UpstreamAttemptFailure>?>(nil)
        let (_, continuation) = AsyncThrowingStream<UpstreamResponseEvent, Error>.makeStream()
        slot.arm(continuation: continuation, methodIsHead: false) { result in
            outcome.withLock { $0 = result }
        }

        let result = outcome.withLock { $0 }
        guard case let .failure(failure)? = result else {
            Issue.record("the held failure must fail the arm; got \(String(describing: result))")
            return
        }
        #expect(failure.underlying is HandshakeStory)
        #expect(!failure.didYield)
    }

    // MARK: - Identity-scoped drain

    @Test func drainByIdentity_closesOnlyThatIdentitysParkedConnections() throws {
        // An in-place PKCS#12 edit changes neither the label nor the pool key, so
        // connections handshaken under the old certificate keep being leased for
        // as long as traffic keeps them from idling out — unless the certificate
        // write drains them.
        let pool = UpstreamConnectionPool()
        func park(_ identity: String?) throws -> UpstreamConnection {
            let channel = EmbeddedChannel()
            try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
            let connection = UpstreamConnection(
                key: UpstreamPoolKey(host: "corp.example.test", port: 443, isTLS: true, identity: identity),
                channel: channel, slot: UpstreamExchangeSlot()
            )
            pool.release(connection)
            return connection
        }
        let corp = try park("corp-client")
        let plain = try park(nil)
        #expect(pool.idleCount == 2)

        pool.drain(identityLabel: "corp-client")

        #expect(pool.idleCount == 1, "the identity's connections go; everyone else's stay")
        #expect(!corp.isUsable)
        #expect(plain.isUsable)
        plain.close()
    }

    // MARK: - The reuse predicate, directly

    @Test func responseIsReusable_readsFramingNotJustKeepAlive() {
        func head(_ status: HTTPResponseStatus, _ pairs: [(String, String)], version: HTTPVersion = .http1_1) -> HTTPResponseHead {
            var headers = HTTPHeaders()
            for pair in pairs { headers.add(name: pair.0, value: pair.1) }
            return HTTPResponseHead(version: version, status: status, headers: headers)
        }
        let reusable = UpstreamExchangeSlot.responseIsReusable

        #expect(reusable(head(.ok, [("Content-Length", "3")]), false))
        #expect(reusable(head(.ok, [("Transfer-Encoding", "chunked")]), false))
        #expect(reusable(head(.noContent, []), false), "204 carries no body to frame")
        #expect(reusable(head(.notModified, []), false), "304 carries no body to frame")
        #expect(reusable(head(.ok, []), true), "a HEAD response carries no body to frame")

        #expect(!reusable(head(.ok, [("Content-Length", "3"), ("Connection", "close")]), false))
        #expect(!reusable(head(.ok, [("Content-Length", "3")], version: .http1_0), false))
        #expect(!reusable(head(.ok, []), false), "close-delimited: the body ends when the socket does")
        #expect(!reusable(head(.switchingProtocols, []), false),
                "after 101 the wire is no longer HTTP/1.1 messages; there is nothing to pool")
    }
}

/// Connections the test server accepted. A class rather than a bare `Mutex`
/// because a noncopyable value can't be captured by the bootstrap's escaping
/// initializer closure.
final class AcceptCounter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

/// A raw-bytes server speaking the `Expect: 100-continue` exchange verbatim:
/// `100 Continue` as its own head+end message, then the final response — the
/// sequence the HTTP-shaped responder above cannot produce (the server pipeline
/// owns response framing and does not write informational heads).
private final class RawInterimResponder: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// "payload".utf8.count — what the test's requests carry.
    private static let expectedBodyBytes = 7

    private var pending = ""
    private var served = 0

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        pending += buffer.readString(length: buffer.readableBytes) ?? ""
        while let headerEnd = pending.range(of: "\r\n\r\n") {
            let afterHeaders = pending[headerEnd.upperBound...]
            guard afterHeaders.utf8.count >= Self.expectedBodyBytes else { return }
            let consumedThrough = pending.index(headerEnd.upperBound, offsetBy: Self.expectedBodyBytes)
            pending = String(pending[consumedThrough...])
            served += 1
            let body = served == 1 ? "first" : "second"
            write(context: context, "HTTP/1.1 100 Continue\r\n\r\n")
            write(context: context, "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        }
    }

    private func write(context: ChannelHandlerContext, _ text: String) {
        var buffer = context.channel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }
}

/// Answers by path, with the framing each test needs.
private final class PoolTestResponder: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    static let deflatedPlaintext = "compressed payload, compressed payload"

    private var path = ""
    private var body = ""

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            path = String(head.uri.prefix(while: { $0 != "?" }))
            body = ""
        case var .body(buffer):
            body += buffer.readString(length: buffer.readableBytes) ?? ""
        case .end:
            respond(context: context)
        }
    }

    private func respond(context: ChannelHandlerContext) {
        switch path {
        case "/echo":
            write(context: context, body: body, extra: [])
        case "/close":
            write(context: context, body: "closed", extra: [("Connection", "close")], thenClose: true)
        case "/nolength":
            // Deliberately unframed: no Content-Length, no chunked. The body is
            // whatever arrives before the close.
            let head = HTTPResponseHead(version: .http1_1, status: .ok)
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: 8)
            buffer.writeString("unframed")
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                context.close(promise: nil)
            }
        case "/reap":
            // A well-framed, keep-alive response — and then the origin reaps the
            // socket anyway, the way a real idle timeout does.
            write(context: context, body: "reaped", extra: [], thenClose: true, announceClose: false)
        case "/deflate":
            let compressed = Self.zlibDeflate(Data(Self.deflatedPlaintext.utf8))
            var headers = HTTPHeaders()
            headers.add(name: "Content-Encoding", value: "deflate")
            headers.add(name: "Content-Length", value: String(compressed.count))
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: compressed.count)
            buffer.writeBytes(compressed)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        case "/slow":
            context.eventLoop.scheduleTask(in: .milliseconds(120)) {
                self.write(context: context, body: "slow", extra: [])
            }
        default:
            write(context: context, body: "ok", extra: [])
        }
    }

    private func write(
        context: ChannelHandlerContext, body: String, extra: [(String, String)],
        thenClose: Bool = false, announceClose: Bool = true
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: String(body.utf8.count))
        for pair in extra where announceClose || pair.0.lowercased() != "connection" {
            headers.add(name: pair.0, value: pair.1)
        }
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        let end = context.writeAndFlush(wrapOutboundOut(.end(nil)))
        if thenClose { end.whenComplete { _ in context.close(promise: nil) } }
    }

    /// RFC 1950 zlib stream, same construction as the forwarder suite's responder.
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
