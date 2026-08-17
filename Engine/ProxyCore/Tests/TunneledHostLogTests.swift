import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// The record that makes a pass-through visible.
///
/// A relayed connection leaves no flow, no request and no error — the same nothing an
/// agent gets when the client never ran. These tests pin the one record that
/// distinguishes them, and the two properties that keep it useful: bounded, and quiet
/// about hosts that are no longer an open question.
@Suite("Tunnelled host log", .timeLimit(.minutes(1)))
struct TunneledHostLogTests {
    @Test func foldsConnectionsIntoOneEntryPerOrigin() throws {
        let log = TunneledHostLog()
        let first = Date(timeIntervalSince1970: 1_000)
        log.record(host: "api.example.com", port: 443, reason: .notInScope, at: first)
        log.record(host: "API.example.com", port: 443, reason: .notInScope, at: first.addingTimeInterval(5))
        log.record(host: "api.example.com", port: 8443, reason: .notInScope, at: first)

        let hosts = log.snapshot().hosts
        // Two entries, not three: the host is case-insensitive, the port is not part
        // of the same origin. Fifty sockets to one origin is one row.
        #expect(hosts.count == 2)
        let merged = try #require(hosts.first { $0.port == 443 })
        #expect(merged.connections == 2)
        #expect(merged.firstSeen == first)
        #expect(merged.lastSeen == first.addingTimeInterval(5))
    }

    @Test func latestReasonWins() {
        let log = TunneledHostLog()
        log.record(host: "h.test", port: 443, reason: .notInScope)
        log.record(host: "h.test", port: 443, reason: .notTLSOrHTTP)
        // A host moves from "not in scope" to "not TLS at all" the moment someone
        // intercepts it and the bytes turn out to be h2c or SSH; the new reason is
        // the actionable one, and it flips `interceptable` to false.
        #expect(log.snapshot().hosts.first?.reason == .notTLSOrHTTP)
        #expect(log.snapshot().hosts.first?.interceptable == false)
        #expect(log.snapshot().hosts.first?.connections == 1)
        #expect(log.snapshot().hosts.first?.clientTLS == nil)
    }

    @Test func newerReasonKeepsTLSEvidenceAndOlderReasonCannotOverwriteIt() throws {
        let log = TunneledHostLog()
        let base = Date(timeIntervalSince1970: 1_000)
        log.recordClientFailure(
            host: "h.test",
            port: 443,
            code: .clientCertificateRejected,
            at: base
        )
        log.record(
            host: "h.test",
            port: 443,
            reason: .protocolError,
            at: base.addingTimeInterval(2)
        )
        log.record(
            host: "h.test",
            port: 443,
            reason: .notTLSOrHTTP,
            at: base.addingTimeInterval(1)
        )

        let entry = try #require(log.snapshot().hosts.first)
        #expect(entry.reason == .protocolError)
        #expect(entry.clientTLS?.failureCount == 1)
        #expect(entry.clientTLS?.lastFailureCode == .clientCertificateRejected)
    }

    @Test func clientSuccessKeepsMixedEvidenceAndLatestResult() throws {
        let log = TunneledHostLog()
        let failedAt = Date(timeIntervalSince1970: 1_000)
        let recoveredAt = failedAt.addingTimeInterval(1)

        log.recordClientFailure(
            host: "api.example.test", port: 443,
            code: .clientCertificateRejected,
            detail: "certificate_unknown",
            at: failedAt
        )
        log.recordClientSuccess(
            host: "api.example.test", port: 443,
            at: recoveredAt
        )

        let entry = try #require(log.snapshot().hosts.first)
        #expect(entry.clientTLS?.status == .mixed)
        #expect(entry.clientTLS?.latestResult == .succeeded)
        #expect(entry.clientTLS?.failureCount == 1)
        #expect(entry.clientTLS?.successCount == 1)
        #expect(entry.clientTLS?.lastFailureAt == failedAt)
        #expect(entry.clientTLS?.lastSuccessAt == recoveredAt)
        #expect(entry.clientTLS?.lastFailureCode == .clientCertificateRejected)
        #expect(entry.detail == "certificate_unknown")
    }

    @Test func aHealthyHandshakeDoesNotCreateAHostEntry() {
        let log = TunneledHostLog()
        log.recordClientSuccess(host: "healthy.example.test", port: 443)
        #expect(log.snapshot().hosts.isEmpty)
    }

    @Test func successBeforeFirstFailureIsMergedWithoutListingAHealthyHost() throws {
        let log = TunneledHostLog()
        let base = Date(timeIntervalSince1970: 1_000)
        log.recordClientSuccess(host: "api.example.test", port: 443, at: base)
        #expect(log.snapshot().hosts.isEmpty)

        log.recordClientFailure(
            host: "api.example.test",
            port: 443,
            code: .clientCertificateRejected,
            at: base.addingTimeInterval(1)
        )
        let observation = try #require(log.snapshot().hosts.first?.clientTLS)
        #expect(observation.failureCount == 1)
        #expect(observation.successCount == 1)
        #expect(observation.status == .mixed)
        #expect(observation.latestResult == .failed)
    }

    @Test func eventArrivalOrderDoesNotOverrideChronologicalStatus() throws {
        let log = TunneledHostLog()
        let base = Date(timeIntervalSince1970: 1_000)
        log.recordClientFailure(
            host: "api.example.test", port: 443,
            code: .clientHandshakeFailed, at: base
        )
        log.recordClientSuccess(
            host: "api.example.test", port: 443,
            at: base.addingTimeInterval(30)
        )
        // Arrives later on another event loop, but happened before the success.
        log.recordClientFailure(
            host: "api.example.test", port: 443,
            code: .clientHandshakeAborted,
            at: base.addingTimeInterval(20)
        )

        let observation = try #require(log.snapshot().hosts.first?.clientTLS)
        #expect(observation.status == .mixed)
        #expect(observation.latestResult == .succeeded)
        #expect(observation.failureCount == 2)
        #expect(observation.successCount == 1)
        #expect(observation.lastFailureAt == base.addingTimeInterval(20))
        #expect(observation.lastSuccessAt == base.addingTimeInterval(30))
    }

    @Test func newestActivityFirst() {
        let log = TunneledHostLog()
        let base = Date(timeIntervalSince1970: 2_000)
        log.record(host: "old.test", port: 443, reason: .notInScope, at: base)
        log.record(host: "new.test", port: 443, reason: .notInScope, at: base.addingTimeInterval(60))
        #expect(log.snapshot().hosts.map(\.host) == ["new.test", "old.test"])
    }

    @Test func boundedByCapacity_evictingLeastRecentlyActive_andCountingWhatWent() {
        let log = TunneledHostLog()
        let base = Date(timeIntervalSince1970: 3_000)
        // One past the cap, with the *first* host the stalest.
        for index in 0 ... TunneledHostLog.capacity {
            log.record(
                host: "host\(index).test", port: 443, reason: .notInScope,
                at: base.addingTimeInterval(Double(index))
            )
        }
        let snapshot = log.snapshot()
        #expect(snapshot.hosts.count == TunneledHostLog.capacity)
        #expect(snapshot.evicted == 1, "a truncated list must never read as a complete one")
        #expect(!snapshot.hosts.contains { $0.host == "host0.test" }, "least recently active goes first")
        #expect(snapshot.hosts.contains { $0.host == "host\(TunneledHostLog.capacity).test" })
    }

    @Test func hiddenSuccessEvidenceIsBoundedAndItsLossIsCounted() {
        let log = TunneledHostLog()
        let base = Date(timeIntervalSince1970: 4_000)
        for index in 0 ... TunneledHostLog.capacity {
            log.recordClientSuccess(
                host: "host\(index).test",
                port: 443,
                at: base.addingTimeInterval(Double(index))
            )
        }
        let snapshot = log.snapshot()
        #expect(snapshot.hosts.isEmpty)
        #expect(snapshot.clientSuccessesEvicted == 1)
    }

    // MARK: pending(_:under:)

    @Test func aHostTheScopeNowDecrypts_stopsBeingOffered() throws {
        let entry = TunneledHost(
            host: "api.example.com", port: 443, firstSeen: Date(), lastSeen: Date(), reason: .notInScope
        )
        let scope = SSLScope(enabled: true, include: ["*.example.com"])
        // Offering "intercept this" for something already intercepted reads as the
        // action having failed.
        #expect(TunneledHostLog.pending([entry], under: scope).isEmpty)
    }

    @Test func aHostNoScopeChangeFixes_staysListedEvenWhenInScope() throws {
        let entry = TunneledHost(
            host: "ssh.example.com", port: 22, firstSeen: Date(), lastSeen: Date(), reason: .notTLSOrHTTP
        )
        let scope = SSLScope(enabled: true, include: ["*"])
        // Still unread. Dropping it because the scope "covers" it is how the
        // server-first / h2c case becomes invisible a second time.
        #expect(TunneledHostLog.pending([entry], under: scope).count == 1)
    }

    @Test func anExcludedHostStaysListed_becauseTheExclusionIsReversible() throws {
        let entry = TunneledHost(
            host: "dl.google.com", port: 443, firstSeen: Date(), lastSeen: Date(), reason: .excluded
        )
        let scope = SSLScope(enabled: true, include: ["*"], exclude: ["*.google.com"])
        #expect(TunneledHostLog.pending([entry], under: scope).count == 1)
    }

    // MARK: End to end

    /// The load-bearing case: an out-of-scope `CONNECT` used to leave nothing at all
    /// behind, which is byte-for-byte what an agent sees when the client never ran.
    @Test func anOutOfScopeCONNECT_isRecordedWithItsReason() async throws {
        let engine = ProxyEngine(
            forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore()
        )
        let port = try await engine.start(port: 0)
        // Interception on with nothing in scope: not the shipping default, but the
        // narrowest way to drive a pass-through, and the state this record explains.
        await engine.setSSLScope(SSLScope(enabled: true, include: []))

        // A listener to CONNECT to, so the tunnel actually establishes.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownBlocking(group) }
        let origin = try await ServerBootstrap(group: group)
            .childChannelInitializer { _ in group.next().makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { origin.close(promise: nil) }
        let originPort = try #require(origin.localAddress?.port)

        let loop = group.next()
        let acked = loop.makePromise(of: Void.self)
        let connect = CONNECTAckHandler(
            // A resolvable authority: `openTunnel` connects upstream before the ack,
            // so a name that doesn't resolve means no ack and a hung test rather than
            // a missing record (the record is written at the decision, above it).
            request: "CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
            acked: acked
        )
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(connect) }
            .connect(host: "127.0.0.1", port: port).get()
        defer { client.close(promise: nil) }
        try await acked.futureResult.get()

        let report = await engine.tunneledHosts()
        let entry = try #require(report.hosts.first { $0.host == "127.0.0.1" && $0.port == originPort })
        #expect(entry.reason == .notInScope, "distinguishes 'add it to the list' from 'can't be read'")
        #expect(entry.interceptable)
        #expect(entry.connections == 1)
        // Terminal, at the end of the body rather than in a `defer`, for the
        // reason `EngineTeardown.swift` gives: a `defer` cannot await, and the
        // blocking bridge that let it try parks a cooperative-pool thread.
        await engine.stopForTest()
    }

    /// The attribution both entry points share. Deliberately unit-level: driving a
    /// real in-scope `CONNECT` and then reading the log races the 150 ms sniff
    /// deadline — a client that sends no ClientHello is eventually classified
    /// `.notTLSOrHTTP` and *does* get recorded, correctly, so an end-to-end
    /// "shouldn't be listed" assertion would pass or fail on timing.
    @Test func passthroughReason_prefersTheScopeVerdictOverAMissingCA() throws {
        let ca = try CertificateAuthority.loadOrGenerate(store: InMemoryCAStore())

        // In scope with a CA: nothing to report, so the connection is sniffed.
        #expect(ProxyHandler.passthroughReason(
            host: "api.example.com",
            config: InterceptionConfig(scope: SSLScope(enabled: true, include: ["*"]), defaults: nil),
            ca: ca
        ) == nil)

        // No CA is the *less* actionable of two truths, so the scope's verdict wins:
        // telling someone to generate a CA for a host they never asked to decrypt
        // sends them the wrong way.
        #expect(ProxyHandler.passthroughReason(
            host: "api.example.com",
            config: InterceptionConfig(scope: SSLScope(enabled: true, include: []), defaults: nil),
            ca: nil
        ) == .notInScope)

        #expect(ProxyHandler.passthroughReason(
            host: "api.example.com",
            config: InterceptionConfig(scope: SSLScope(enabled: true, include: ["*"]), defaults: nil),
            ca: nil
        ) == .noCertificateAuthority)

        #expect(ProxyHandler.passthroughReason(
            host: "dl.google.com",
            config: InterceptionConfig(
                scope: SSLScope(enabled: true, include: ["*"], exclude: ["*.google.com"]), defaults: nil
            ),
            ca: ca
        ) == .excluded)

        #expect(ProxyHandler.passthroughReason(
            host: "api.example.com",
            config: InterceptionConfig(scope: SSLScope(enabled: false, include: ["*"]), defaults: nil),
            ca: ca
        ) == .interceptionDisabled)
    }

    /// `interceptHost` is one engine call rather than the read-modify-write an agent
    /// would otherwise do, because the human at the console is an independent writer
    /// of the same scope.
    @Test func interceptHost_narrowsTheScopeAndClearsTheEntry() async throws {
        let engine = ProxyEngine(
            forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore()
        )
        TunneledHostLog.shared.record(host: "api.example.com", port: 443, reason: .notInScope)

        let outcome = await engine.interceptHost("api.example.com")
        #expect(outcome.effective)
        #expect(outcome.enabledInterception, "the scope started disabled")

        let scope = await engine.sslScope()
        #expect(scope.enabled)
        #expect(scope.include == ["api.example.com"])
        // Scoped to this test's own host, never `hosts.isEmpty`: the log is
        // process-wide and any suite driving a pass-through CONNECT beside this
        // one writes to it, so global emptiness is a claim about the whole run.
        #expect(await engine.tunneledHosts().hosts.contains { $0.host == "api.example.com" } == false)
        // Terminal, at the end of the body rather than in a `defer`, for the
        // reason `EngineTeardown.swift` gives: a `defer` cannot await, and the
        // blocking bridge that let it try parks a cooperative-pool thread.
        await engine.stopForTest()
    }
}

/// Clearing the capture is "forget what this session saw", and this log is part of
/// the session.
///
/// It used to survive a clear, which left the console reporting origins — with
/// `connections` counts and an orange icon — whose rows no longer existed anywhere.
/// The two surfaces then answered the same question differently, which is the exact
/// failure the tunnelled-host log was written to prevent, reintroduced from the other
/// side.
@Suite("Clearing forgets both surfaces", .serialized)
struct ClearForgetsTunneledHostsTests {
    @Test func clearFlowsAlsoEmptiesTheTunneledHostLog() async throws {
        let engine = ProxyEngine(persistFlows: false)
        defer { TunneledHostLog.shared.reset() }
        TunneledHostLog.shared.reset()
        TunneledHostLog.shared.record(host: "relayed.example.test", port: 443, reason: .notInScope)
        #expect(await engine.tunneledHosts().hosts.isEmpty == false)

        await engine.clearFlows()

        #expect(await engine.tunneledHosts().hosts.isEmpty,
                "a console still naming hosts whose rows were just cleared is two answers to one question")
        #expect(await engine.recentFlows(limit: 10).isEmpty)
    }
}

/// Decrypting a host has to end the connections that are already relaying it.
///
/// A relayed tunnel is a byte splice, so the requests inside it are invisible for its
/// whole life, and an HTTP client reuses the connection it has — measured on a real
/// app, seven requests over two connections, and a home screen refreshed repeatedly on
/// a connection opened minutes earlier. Without this, an operator clicks Decrypt and
/// watches nothing happen until their client's pool turns over: the setting correct
/// and the surface empty.
@Suite("Decrypting ends the relayed tunnels", .serialized)
struct RelayedTunnelRegistryTests {
    /// A channel that only has to be closeable and identifiable.
    ///
    /// Closure is asserted through `closeFuture`, not `isActive`: an `EmbeddedChannel`
    /// is inactive until it is connected, so `isActive == false` is true of one that
    /// was never touched and would pass whatever this code did.
    private func channel() -> EmbeddedChannel { EmbeddedChannel() }

    private func isClosed(_ watch: ChannelCloseWatch, _ channel: EmbeddedChannel) -> Bool {
        channel.embeddedEventLoop.run()
        return watch.closed
    }

    @Test func decryptingAHostClosesItsOpenTunnels() throws {
        let registry = RelayedTunnelRegistry()
        let doomed = channel(), spared = channel()
        let doomedWatch = ChannelCloseWatch(doomed), sparedWatch = ChannelCloseWatch(spared)
        registry.register(host: "api.example.test", port: 443, client: doomed)
        registry.register(host: "other.example.test", port: 443, client: spared)

        #expect(registry.closeTunnels(matching: "api.example.test") == 1)
        #expect(isClosed(doomedWatch, doomed))
        #expect(isClosed(sparedWatch, spared) == false, "a host nobody decrypted keeps its connection")
        #expect(registry.count == 1, "and only the closed one leaves the registry")
        _ = try? spared.finish()
    }

    /// An include entry is a **glob**, so decrypting `*.corp` has to end the tunnels
    /// to every host it covers — otherwise the one write the operator made covers a
    /// domain while its live connections stay opaque.
    @Test func aGlobClosesEveryTunnelItCovers() throws {
        let registry = RelayedTunnelRegistry()
        let a = channel(), b = channel(), outside = channel()
        let wa = ChannelCloseWatch(a), wb = ChannelCloseWatch(b), wo = ChannelCloseWatch(outside)
        registry.register(host: "api.corp", port: 443, client: a)
        registry.register(host: "cdn.corp", port: 8443, client: b)
        registry.register(host: "api.other", port: 443, client: outside)

        #expect(registry.closeTunnels(matching: "*.corp") == 2)
        #expect(isClosed(wa, a))
        #expect(isClosed(wb, b), "the port is not part of the decision — a host is")
        #expect(isClosed(wo, outside) == false)
        _ = try? outside.finish()
    }

    /// `setSSLScope` cannot name one host, so closing is "every tunnel the new
    /// scope would decrypt". A host still unnamed, or still excluded, reconnects
    /// into another relay and must be left alone.
    @Test func aScopeClosesOnlyTheTunnelsItWouldDecrypt() throws {
        let registry = RelayedTunnelRegistry()
        let decrypted = channel(), unread = channel(), excluded = channel()
        let wd = ChannelCloseWatch(decrypted), wu = ChannelCloseWatch(unread), we = ChannelCloseWatch(excluded)
        registry.register(host: "api.example.test", port: 443, client: decrypted)
        registry.register(host: "other.example.test", port: 443, client: unread)
        registry.register(host: "pinned.example.test", port: 443, client: excluded)

        let scope = SSLScope(
            enabled: true, include: ["api.example.test", "pinned.example.test"],
            exclude: ["pinned.example.test"]
        )
        #expect(registry.closeTunnels(interceptedBy: scope) == 1)
        #expect(isClosed(wd, decrypted))
        #expect(isClosed(wu, unread) == false)
        #expect(isClosed(we, excluded) == false, "an exclude still shadows it")
        _ = try? unread.finish()
        _ = try? excluded.finish()
    }

    /// Matched case-insensitively, because DNS is and nothing normalizes what a client
    /// put in its `CONNECT` line.
    @Test func hostsMatchCaseInsensitively() throws {
        let registry = RelayedTunnelRegistry()
        let c = channel()
        let watch = ChannelCloseWatch(c)
        registry.register(host: "API.Example.Test", port: 443, client: c)
        #expect(registry.closeTunnels(matching: "api.example.test") == 1)
        #expect(isClosed(watch, c))
    }

    /// Entries remove themselves when the tunnel ends on its own, which is nearly all
    /// of them. Without that the registry would grow for the life of the process and
    /// hold a reference to every socket ever spliced.
    @Test func aClosedTunnelLeavesTheRegistry() throws {
        let registry = RelayedTunnelRegistry()
        let c = channel()
        registry.register(host: "api.example.test", port: 443, client: c)
        #expect(registry.count == 1)

        _ = try? c.finish()
        c.embeddedEventLoop.run()
        #expect(registry.count == 0)
        #expect(registry.closeTunnels(matching: "api.example.test") == 0)
    }

    /// A host with nothing open is the ordinary case and must not look like an error.
    @Test func decryptingAQuietHostClosesNothing() {
        #expect(RelayedTunnelRegistry().closeTunnels(matching: "never.seen.test") == 0)
    }
}

/// `EventLoopFuture` has no "did it complete" query in this NIO version, and
/// `EmbeddedChannel.isActive` is false for a channel that was never connected — so a
/// naive `isActive == false` passes whatever the code under test did. This records
/// the closure as it happens.
final class ChannelCloseWatch: @unchecked Sendable {
    private(set) var closed = false
    init(_ channel: EmbeddedChannel) {
        channel.closeFuture.whenComplete { [self] _ in closed = true }
    }
}
