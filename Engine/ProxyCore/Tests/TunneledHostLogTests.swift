import Foundation
import NIOCore
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

    // MARK: pending(_:under:)

    @Test func aHostTheScopeNowDecrypts_stopsBeingOffered() {
        let entry = TunneledHost(
            host: "api.example.com", port: 443, firstSeen: Date(), lastSeen: Date(), reason: .notInScope
        )
        let scope = SSLScope(enabled: true, include: ["*.example.com"])
        // Offering "intercept this" for something already intercepted reads as the
        // action having failed.
        #expect(TunneledHostLog.pending([entry], under: scope).isEmpty)
    }

    @Test func aHostNoScopeChangeFixes_staysListedEvenWhenInScope() {
        let entry = TunneledHost(
            host: "ssh.example.com", port: 22, firstSeen: Date(), lastSeen: Date(), reason: .notTLSOrHTTP
        )
        let scope = SSLScope(enabled: true, include: ["*"])
        // Still unread. Dropping it because the scope "covers" it is how the
        // server-first / h2c case becomes invisible a second time.
        #expect(TunneledHostLog.pending([entry], under: scope).count == 1)
    }

    @Test func anExcludedHostStaysListed_becauseTheExclusionIsReversible() {
        let entry = TunneledHost(
            host: "dl.google.com", port: 443, firstSeen: Date(), lastSeen: Date(), reason: .excluded
        )
        let scope = SSLScope(enabled: true, include: ["*"], exclude: ["*.google.com"])
        #expect(TunneledHostLog.pending([entry], under: scope).count == 1)
    }

    // MARK: End to end

    /// The load-bearing case: an out-of-scope `CONNECT` used to leave nothing at all
    /// behind, which is byte-for-byte what an agent sees when the client never ran.
    @Test func anOutOfScopeCONNECT_isRecordedWithItsReason() throws {
        TunneledHostLog.shared.reset()
        let engine = ProxyEngine(
            forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore()
        )
        let port = try runBlocking { try await engine.start(port: 0) }
        // Interception on with nothing in scope: not the shipping default, but the
        // narrowest way to drive a pass-through, and the state this record explains.
        runBlockingVoid { await engine.setSSLScope(SSLScope(enabled: true, include: [])) }
        defer { runBlockingVoid { await engine.shutdown() } }

        // A listener to CONNECT to, so the tunnel actually establishes.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownBlocking(group) }
        let origin = try ServerBootstrap(group: group)
            .childChannelInitializer { _ in group.next().makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { try? origin.close().wait() }
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
        let client = try ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(connect) }
            .connect(host: "127.0.0.1", port: port).wait()
        defer { try? client.close().wait() }
        try acked.futureResult.wait()

        let report = try runBlocking { await engine.tunneledHosts() }
        let entry = try #require(report.hosts.first { $0.host == "127.0.0.1" && $0.port == originPort })
        #expect(entry.reason == .notInScope, "distinguishes 'add it to the list' from 'can't be read'")
        #expect(entry.interceptable)
        #expect(entry.connections == 1)
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
    @Test func interceptHost_narrowsTheScopeAndClearsTheEntry() throws {
        TunneledHostLog.shared.reset()
        let engine = ProxyEngine(
            forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore()
        )
        defer { runBlockingVoid { await engine.shutdown() } }
        TunneledHostLog.shared.record(host: "api.example.com", port: 443, reason: .notInScope)

        let outcome = try runBlocking { await engine.interceptHost("api.example.com") }
        #expect(outcome.effective)
        #expect(outcome.enabledInterception, "the scope started disabled")

        let scope = try runBlocking { await engine.sslScope() }
        #expect(scope.enabled)
        #expect(scope.include == ["api.example.com"])
        #expect(try runBlocking { await engine.tunneledHosts() }.hosts.isEmpty)
    }
}
