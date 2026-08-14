import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOSSL
import NIOTLS
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// The limits Loom's intercepted HTTP/2 server advertises, and what happens to a
/// stream its codec cannot read.
///
/// Both were found the same way — a real app's home screen hung forever with an
/// empty capture — and both are about the same rule: **a proxy must not be
/// stricter than the origin, and when it is, it must say so instead of going
/// quiet.** Measured against a real API: a 20 KB `Cookie` header answered in 58 ms
/// direct and in 196 ms through Loom's HTTP/1.1 path, while Loom's h2 path hung
/// until the client's own timeout, with no flow, no RST_STREAM and no GOAWAY.
@Suite("HTTP/2 header limits")
struct HTTP2HeaderLimitTests {
    @Test func advertisedHeaderListSizeIsFarAboveSwiftNIOsDefault() {
        // SwiftNIO advertises `HPACKDecoder.defaultMaxHeaderListSize` (16 KB), whose
        // own comment calls the value "somewhat arbitrary". A phone's session
        // cookies reach 15–31 KB, so that default rejects ordinary traffic that
        // works fine without Loom in the path.
        #expect(MITMPipeline.maxHeaderListSize == 1 << 20)
        #expect(MITMPipeline.maxHeaderListSize > 1 << 14,
                "the point of the setting is to be larger than the default it replaces")
    }

    @Test func aCodecErrorIsRecordedAgainstTheHostAndCannotBeSilent() throws {
        // The reporter's contract, without standing up an h2 peer to break: an error
        // reaching it must land in the one surface that answers "why is this host
        // missing from my capture", carrying what the codec actually said.
        let log = TunneledHostLog()
        let reporter = HTTP2ConnectionErrorReporter(host: "api.example.test", port: 443, log: log)
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(reporter)

        channel.pipeline.fireErrorCaught(NIOHTTP2Errors.excessivelyLargeHeaderBlock())

        let entry = log.snapshot().hosts.first { $0.host == "api.example.test" }
        #expect(entry?.reason == .protocolError)
        #expect(entry?.detail?.contains("HeaderBlock") == true || entry?.detail?.isEmpty == false,
                "the codec's own words are what separate 'your client sent too much' from 'Loom broke'")
        #expect(entry?.interceptable == false, "no scope change makes an unreadable stream readable")
        #expect(entry?.brokeTheClient == true, "this request did not happen — it is a broken page, not an opaque one")
        _ = try? channel.finish()
    }

    @Test func closingIsTheOnlyAnswerAvailableAfterAnUndecodableHeaderBlock() throws {
        // HPACK's dynamic table is per-connection state (RFC 7541 §2.3), so a header
        // block that could not be decoded leaves every later block on that
        // connection undecodable too. RFC 9113 §5.4.1: a connection error is
        // signalled and the connection closed. Staying open is what produced the
        // infinite spinner.
        let log = TunneledHostLog()
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            HTTP2ConnectionErrorReporter(host: "api.example.test", port: 443, log: log)
        )
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()

        channel.pipeline.fireErrorCaught(NIOHTTP2Errors.excessivelyLargeHeaderBlock())
        channel.embeddedEventLoop.run()

        #expect(channel.isActive == false, "the client must learn the request will never be answered")
        _ = try? channel.finish()
    }

    @Test func aStreamErrorNeitherClosesTheConnectionNorDefamesTheHost() throws {
        // RFC 9113 §5.4.2: a stream error is answered with RST_STREAM and the
        // connection continues. NIOHTTP2 has already done exactly that by the time
        // the wrapped error reaches the tail — closing here would kill every other
        // in-flight stream for one stream's failure, and recording it would list a
        // working host as broken.
        let log = TunneledHostLog()
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            HTTP2ConnectionErrorReporter(host: "api.example.test", port: 443, log: log)
        )
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()

        channel.pipeline.fireErrorCaught(
            NIOHTTP2Errors.streamError(
                streamID: HTTP2StreamID(3),
                baseError: NIOHTTP2Errors.streamClosed(streamID: HTTP2StreamID(3), errorCode: .cancel)
            )
        )
        channel.embeddedEventLoop.run()

        #expect(channel.isActive == true, "RST_STREAM already answered this; the connection is still usable")
        #expect(log.snapshot().hosts.isEmpty, "a cancelled stream is not a broken host")
        _ = try? channel.finish()
    }

    @Test func transportTeardownIsClosedButNeverRecordedAsAProtocolError() throws {
        // Measured on a real device within a day of the reporter shipping: the
        // app's main API host — every request captured, every response 200 — was
        // listed as `protocolError` with "Connection reset by peer", because a
        // phone tears down idle connections with RST instead of close_notify.
        // Teardown noise on the "why is this host broken" surface teaches the
        // operator to ignore the surface.
        let teardowns: [any Error] = [
            NIOSSLError.uncleanShutdown,
            IOError(errnoCode: ECONNRESET, reason: "read(descriptor:pointer:size:)"),
            ChannelError.ioOnClosedChannel,
        ]
        for error in teardowns {
            let log = TunneledHostLog()
            let channel = EmbeddedChannel()
            try channel.pipeline.syncOperations.addHandler(
                HTTP2ConnectionErrorReporter(host: "api.example.test", port: 443, log: log)
            )
            try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()

            channel.pipeline.fireErrorCaught(error)
            channel.embeddedEventLoop.run()

            #expect(channel.isActive == false, "an answer is still owed if anything was waiting: \(error)")
            #expect(log.snapshot().hosts.isEmpty, "teardown is not a codec failure: \(error)")
            _ = try? channel.finish()
        }
    }

    @Test func anUnrecognisedErrorFailsClosedIntoTheFatalTier() {
        // The tiering must never reintroduce the silent hang: anything the
        // classifier does not positively recognise as stream-scoped or transport
        // gets the record-and-close treatment. A wrongly-closed connection is
        // retried by the client; a wrongly-kept one waits forever.
        struct SomeFutureCodecError: Error {}
        #expect(HTTP2ConnectionErrorReporter.classify(SomeFutureCodecError()) == .connectionFatal)
        #expect(HTTP2ConnectionErrorReporter.classify(NIOHTTP2Errors.excessivelyLargeHeaderBlock()) == .connectionFatal)
        #expect(HTTP2ConnectionErrorReporter.classify(NIOSSLError.uncleanShutdown) == .transportTeardown)
        #expect(HTTP2ConnectionErrorReporter.classify(
            NIOHTTP2Errors.streamError(streamID: HTTP2StreamID(1), baseError: SomeFutureCodecError())
        ) == .streamScoped)
    }
}

/// The recovery half: a failure verdict on a host must not outlive the failure.
@Suite("Client verdict recovery")
struct ClientVerdictRecoveryTests {
    @Test func aCompletedHandshakeClearsTheHostsFailureVerdict() throws {
        // `clientHandshakeFailed` and `protocolError` have no scope-change recovery
        // path — `pending()` keeps them deliberately. The evidence that clears them
        // is a client completing a handshake against Loom's leaf, which is exactly
        // what installing the CA produces.
        let log = TunneledHostLog()
        log.record(host: "pinned.example.test", port: 443, reason: .clientHandshakeFailed)
        #expect(log.snapshot().hosts.count == 1)

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ClientTLSFailureReporter(host: "pinned.example.test", port: 443, log: log)
        )
        channel.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: "h2"))
        channel.embeddedEventLoop.run()

        #expect(log.snapshot().hosts.isEmpty,
                "the operator who just installed the CA must see the entry go, not haunt until relaunch")
        _ = try? channel.finish()
    }

    @Test func aHandshakeClearsOnlyClientVerdicts_neverAScopeDecision() {
        // An `excluded` entry is the configuration working; a handshake elsewhere
        // on the same host:port (impossible for excluded hosts today, but the
        // guard is the contract) must not un-list it.
        let log = TunneledHostLog()
        log.record(host: "carved-out.example.test", port: 443, reason: .excluded)
        log.clearClientVerdicts(host: "carved-out.example.test", port: 443)
        #expect(log.snapshot().hosts.count == 1)
    }

    @Test func aFailureAfterRecoveryRecordsItselfAgain() {
        // The window where a cleared entry hides a live problem is one connection
        // wide: the next failure re-records immediately.
        let log = TunneledHostLog()
        log.record(host: "flaky.example.test", port: 443, reason: .protocolError, detail: "first")
        log.clearClientVerdicts(host: "flaky.example.test", port: 443)
        log.record(host: "flaky.example.test", port: 443, reason: .protocolError, detail: "second")
        let entry = log.snapshot().hosts.first
        #expect(entry?.reason == .protocolError)
        #expect(entry?.detail == "second")
        #expect(entry?.connections == 1, "recovery reset the count — these are new refusals, not a running total")
    }
}

/// A connection Loom broke is a **row**, not only a log line.
///
/// `TunneledHostLog` answers "which origins went unread" for the console and for an
/// agent. It is not what the operator is looking at when a request produced nothing:
/// that is the request table, and until this the table held *no row at all* for a
/// refused handshake — the client showed a certificate error against a capture
/// denying the host had ever been contacted. It is the same failure the tunnelled-host
/// log was written for, left open on the path where the request did not merely go
/// unread but never happened.
@Suite("A failed interception is recorded as a flow")
struct FailedInterceptionFlowTests {
    private func failureFlow(in store: FlowStore) async -> Flow? {
        await store.recent(limit: 20).first { $0.request.method == "CONNECT" && $0.error != nil }
    }

    @Test func aRefusedClientHandshakeBecomesACONNECTRowCarryingTheError() async throws {
        let log = TunneledHostLog()
        let store = FlowStore()
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ClientTLSFailureReporter(host: "pinned.example.test", port: 443, log: log, store: store)
        )

        channel.pipeline.fireErrorCaught(NIOSSLError.handshakeFailed(.sslError([])))
        channel.embeddedEventLoop.run()

        var flow: Flow?
        for _ in 0..<200 where flow == nil {
            flow = await failureFlow(in: store)
            if flow == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        #expect(flow?.request.url == "https://pinned.example.test:443")
        #expect(flow?.error?.contains("refused Loom's certificate") == true,
                "the row has to name what Loom did, or it reads as the origin's fault")
        // And the aggregate still exists — the two surfaces answer different questions.
        #expect(log.snapshot().hosts.first?.reason == .clientHandshakeFailed)
        _ = try? channel.finish()
    }

    @Test func anUnreadableHTTP2ConnectionBecomesACONNECTRowToo() async throws {
        let log = TunneledHostLog()
        let store = FlowStore()
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            HTTP2ConnectionErrorReporter(host: "h2.example.test", port: 443, log: log, store: store)
        )

        channel.pipeline.fireErrorCaught(NIOHTTP2Errors.excessivelyLargeHeaderBlock())
        channel.embeddedEventLoop.run()

        var flow: Flow?
        for _ in 0..<200 where flow == nil {
            flow = await failureFlow(in: store)
            if flow == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        #expect(flow?.request.url == "https://h2.example.test:443")
        #expect(flow?.error?.contains("could not read") == true)
        _ = try? channel.finish()
    }

    /// Ordinary teardown is not a failed interception. A phone dropping an idle
    /// connection with RST is normal mobile behaviour, and a row per instance would
    /// bury the ones that mean something — the same reasoning that gave the h2
    /// reporter its three tiers.
    @Test func transportTeardownRecordsNoRow() async throws {
        let store = FlowStore()
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            HTTP2ConnectionErrorReporter(host: "quiet.example.test", port: 443,
                                         log: TunneledHostLog(), store: store)
        )

        channel.pipeline.fireErrorCaught(NIOSSLError.uncleanShutdown)
        channel.embeddedEventLoop.run()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(await failureFlow(in: store) == nil)
        _ = try? channel.finish()
    }

    /// **A client that just closes the socket is the common refusal, and it raises no
    /// error at all.** `ClientTLSFailureReporter` catches what NIOSSL *reports* — a
    /// fatal alert becomes `handshakeFailed`, which is what a refusing `curl` sends —
    /// but an Android app that pins a certificate typically reads Loom's leaf and hangs
    /// up, so BoringSSL sees a clean EOF and nothing is raised. Measured in use: after
    /// clicking Decrypt on such a host, the operator got no decrypted rows, no failure
    /// row and no log line — the one host they had explicitly asked to read went silent.
    @Test func aClientThatHangsUpMidHandshakeIsStillRecorded() async throws {
        let log = TunneledHostLog()
        let store = FlowStore()
        let attempt = ClientTLSAttempt()
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ClientTLSAbortReporter(host: "pinned.example.test", port: 443,
                                   attempt: attempt, log: log, store: store)
        )

        // A ClientHello's first bytes, then the connection goes away with no alert.
        try channel.writeInbound(ByteBuffer(bytes: [0x16, 0x03, 0x01]))
        channel.pipeline.fireChannelInactive()
        channel.embeddedEventLoop.run()

        var flow: Flow?
        for _ in 0..<200 where flow == nil {
            flow = await failureFlow(in: store)
            if flow == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        #expect(flow?.request.url == "https://pinned.example.test:443")
        #expect(flow?.error?.contains("pins this host") == true,
                "the row has to name the operator's next move, not just say the socket closed")
        #expect(log.snapshot().hosts.first?.reason == .clientHandshakeFailed)
    }

    /// And the discriminator that makes that safe: a tunnel opened ahead of need and
    /// closed unused says nothing about Loom's certificate. Browsers and pooled HTTP
    /// clients do this constantly, so reporting it would put a "decryption failed" row
    /// on every warm connection a browser drops — the same rule `TunnelSniffHandler`
    /// applies to a tunnel that stays silent past its deadline.
    @Test func anAbandonedPreConnectedTunnelIsNotAFailure() async throws {
        let log = TunneledHostLog()
        let store = FlowStore()
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ClientTLSAbortReporter(host: "warm.example.test", port: 443,
                                   attempt: ClientTLSAttempt(), log: log, store: store)
        )

        // No bytes at all — the client never started a handshake.
        channel.pipeline.fireChannelInactive()
        channel.embeddedEventLoop.run()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(await failureFlow(in: store) == nil)
        #expect(log.snapshot().hosts.isEmpty)
    }

    /// A completed handshake ends the question: everything after it belongs to the
    /// exchange, and the connection closing is how every healthy connection ends.
    @Test func aCompletedHandshakeMeansTheCloseIsOrdinary() async throws {
        let store = FlowStore()
        let attempt = ClientTLSAttempt()
        attempt.clientSpoke = true
        attempt.handshakeCompleted = true
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ClientTLSAbortReporter(host: "fine.example.test", port: 443,
                                   attempt: attempt, log: TunneledHostLog(), store: store)
        )

        channel.pipeline.fireChannelInactive()
        channel.embeddedEventLoop.run()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(await failureFlow(in: store) == nil)
    }

    /// The two halves share one attempt, so a refusal that surfaces as an alert *and*
    /// as the connection closing is one row, not two. The host's `connections` count
    /// says how many clients were refused, not how many events each refusal produced.
    @Test func theTwoReportersAgreeOnOneReportPerConnection() async throws {
        let log = TunneledHostLog()
        let store = FlowStore()
        let attempt = ClientTLSAttempt()
        let channel = EmbeddedChannel()
        let sync = channel.pipeline.syncOperations
        try sync.addHandler(
            ClientTLSAbortReporter(host: "pinned.example.test", port: 443,
                                   attempt: attempt, log: log, store: store)
        )
        try sync.addHandler(
            ClientTLSFailureReporter(host: "pinned.example.test", port: 443,
                                     attempt: attempt, log: log, store: store)
        )

        try channel.writeInbound(ByteBuffer(bytes: [0x16, 0x03, 0x01]))
        channel.pipeline.fireErrorCaught(NIOSSLError.handshakeFailed(.sslError([])))
        channel.pipeline.fireChannelInactive()
        channel.embeddedEventLoop.run()
        try? await Task.sleep(nanoseconds: 150_000_000)

        let rows = await store.recent(limit: 20).filter { $0.request.method == "CONNECT" }
        #expect(rows.count == 1)
        #expect(log.snapshot().hosts.first?.connections == 1)
    }

    /// Recording is deliberately **not** gated on `observeTunnels`: that flag is a
    /// volume decision about traffic that worked, and this is a request that never
    /// happened because Loom was in the path. An embedder with no row for it has the
    /// same hole the operator had.
    @Test func aCompletedHandshakeAfterAFailureStillRecordsOnlyOneRow() async throws {
        let store = FlowStore()
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ClientTLSFailureReporter(host: "retry.example.test", port: 443,
                                     log: TunneledHostLog(), store: store)
        )

        // A failing handshake raises several errors on its way down; the row count
        // has to be per connection, like the log's `connections` tally.
        channel.pipeline.fireErrorCaught(NIOSSLError.handshakeFailed(.sslError([])))
        channel.pipeline.fireErrorCaught(NIOSSLError.handshakeFailed(.sslError([])))
        channel.embeddedEventLoop.run()
        try? await Task.sleep(nanoseconds: 150_000_000)

        let rows = await store.recent(limit: 20).filter { $0.request.method == "CONNECT" }
        #expect(rows.count == 1)
        _ = try? channel.finish()
    }
}
