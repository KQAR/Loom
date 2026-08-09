import Testing
import Foundation
import LoomSharedModels
@testable import MCPServer

/// Loom serves two MCP revisions and the old one is a standing tax. ROADMAP
/// § Structured Channel says when it may be dropped, and one of the two conditions is
/// *"a release has shipped with no legacy dispatch recorded"* — which nothing recorded,
/// so the condition could never be evaluated and the tax was permanent by default.
///
/// `MCPEraLog` makes it decidable. What these pin is the part that is easy to get
/// wrong and impossible to notice: **"legacy" is two different facts**, and counting
/// them together would produce a number that never reaches zero (bare requests keep
/// arriving), a condition that never fires, and telemetry that made it look measured.
@Suite struct EraTelemetryTests {
    // MARK: The decision carries its reason

    @Test func aModernRequestIsRecognisedByItsMeta() {
        let decision = MCPProtocol.decide(
            method: "tools/list",
            meta: [MCPProtocol.MetaKey.protocolVersion: MCPProtocol.latest],
            headerVersion: nil
        )
        #expect(decision.reason == .modernMeta)
        #expect(decision.era == .modern)
    }

    @Test func initializeIsEvidenceOfAnOldClient() {
        let decision = MCPProtocol.decide(method: "initialize", meta: [:], headerVersion: nil)
        #expect(decision.reason == .legacyHandshake)
        #expect(decision.era == .legacy)
    }

    /// The case the whole design turns on: a request declaring nothing is legacy by
    /// *fallback*. It might be an old client, a proxy that stripped the metadata, or a
    /// hand-typed curl — so it must not count as evidence.
    @Test func aBareRequestIsLegacyByFallbackAndNotEvidence() {
        let decision = MCPProtocol.decide(method: "tools/list", meta: [:], headerVersion: nil)
        #expect(decision.reason == .legacyBareRequest)
        #expect(decision.era == .legacy)
        #expect(decision.reason.isLegacy)
    }

    @Test func aModernHeaderOverABodyWithNoMetaStillReadsModern() {
        let decision = MCPProtocol.decide(
            method: "tools/list", meta: [:], headerVersion: MCPProtocol.latest
        )
        #expect(decision.reason == .modernHeader)
    }

    /// `era` is a wrapper over `decide`, not a second implementation — two functions
    /// agreeing about how an era is chosen is exactly the pair that stops agreeing.
    @Test func eraAndDecideCannotDisagree() {
        let cases: [(String, [String: Any], String?)] = [
            ("tools/list", [MCPProtocol.MetaKey.protocolVersion: MCPProtocol.latest], nil),
            ("initialize", [:], nil),
            ("tools/list", [:], MCPProtocol.latest),
            ("tools/call", [:], nil),
        ]
        for (method, meta, header) in cases {
            #expect(
                MCPProtocol.era(method: method, meta: meta, headerVersion: header)
                    == MCPProtocol.decide(method: method, meta: meta, headerVersion: header).era
            )
        }
    }

    // MARK: The tally

    @Test func reasonsAreCountedApart() {
        let log = MCPEraLog()
        log.record(reason: .modernMeta, client: nil)
        log.record(reason: .legacyBareRequest, client: nil)
        log.record(reason: .legacyBareRequest, client: nil)

        let snapshot = log.snapshot()
        // Bare requests are legacy, and yet the era stays retirable: that separation is
        // the point of the type.
        #expect(snapshot.counts[.legacyBareRequest] == 2)
        #expect(snapshot.legacyHandshakes == 0)

        log.record(reason: .legacyHandshake, client: nil)
        #expect(log.snapshot().legacyHandshakes == 1)
    }

    @Test func aClientIsTalliedPerEraWithItsLastSighting() {
        let log = MCPEraLog()
        let client = MCPClientIdentity(["name": "claude-code", "version": "2.0"])
        let later = Date(timeIntervalSince1970: 1_000)
        log.record(reason: .legacyHandshake, client: client, at: Date(timeIntervalSince1970: 0))
        log.record(reason: .legacyHandshake, client: client, at: later)

        let snapshot = log.snapshot()
        #expect(snapshot.legacyClients.count == 1)
        #expect(snapshot.legacyClients.first?.name == "claude-code")
        #expect(snapshot.legacyClients.first?.version == "2.0")
        #expect(snapshot.legacyClients.first?.requests == 2)
        #expect(snapshot.legacyClients.first?.lastSeen == later)
        #expect(snapshot.modernClients.isEmpty)
    }

    /// The same client seen on both eras is two sightings, not one: a client mid-
    /// rollover is precisely what the retirement decision is about.
    @Test func aClientOnBothErasAppearsUnderBoth() {
        let log = MCPEraLog()
        let client = MCPClientIdentity(["name": "cursor"])
        log.record(reason: .legacyHandshake, client: client)
        log.record(reason: .modernMeta, client: client)

        let snapshot = log.snapshot()
        #expect(snapshot.legacyClients.map(\.name) == ["cursor"])
        #expect(snapshot.modernClients.map(\.name) == ["cursor"])
    }

    @Test func clientsAreSortedBusiestFirst() {
        let log = MCPEraLog()
        for _ in 0 ..< 3 { log.record(reason: .modernMeta, client: MCPClientIdentity(["name": "loud"])) }
        log.record(reason: .modernMeta, client: MCPClientIdentity(["name": "quiet"]))
        #expect(log.snapshot().modernClients.map(\.name) == ["loud", "quiet"])
    }

    /// A client identity comes off the wire, so the list is capped — and a capped list
    /// says so rather than looking complete.
    @Test func theClientListIsBoundedAndSaysWhatItDropped() {
        let log = MCPEraLog()
        for i in 0 ... MCPEraLog.maxClients {
            log.record(reason: .modernMeta, client: MCPClientIdentity(["name": "client-\(i)"]))
        }
        let snapshot = log.snapshot()
        #expect(snapshot.modernClients.count == MCPEraLog.maxClients)
        #expect(snapshot.modernClientsOmitted == 1)
    }

    /// An unnamed client is not an identity. Inventing one ("unknown") would put a row
    /// in the list that cannot answer the question the list exists for.
    @Test func anUnnamedClientIsNotRecordedAsOne() {
        #expect(MCPClientIdentity(nil) == nil)
        #expect(MCPClientIdentity(["version": "1.0"]) == nil)
        #expect(MCPClientIdentity(["name": ""]) == nil)

        let log = MCPEraLog()
        log.record(reason: .legacyBareRequest, client: nil)
        #expect(log.snapshot().legacyClients.isEmpty)
        #expect(log.snapshot().counts[.legacyBareRequest] == 1)
    }

    // MARK: What `get_version` reports

    @MainActor
    @Test func getVersionOmitsTheTallyWhenNothingIsCounting() async throws {
        let executor = MCPToolExecutor(
            engine: StubEngine(), appVersion: "9.9", protocolVersion: MCPProtocol.latest
        )
        let json = try #require(try JSONSerialization.jsonObject(
            with: Data(try await executor.call(name: "get_version", arguments: [:]).utf8)
        ) as? [String: Any])
        // "No legacy traffic" and "nothing was counting" must not read the same.
        #expect(json["protocolTraffic"] == nil)
    }

    @MainActor
    @Test func getVersionReportsTheTallyAndWhetherTheOldEraCanGo() async throws {
        let log = MCPEraLog()
        log.record(reason: .modernMeta, client: MCPClientIdentity(["name": "claude-code"]))
        log.record(reason: .legacyBareRequest, client: nil)
        var executor = MCPToolExecutor(
            engine: StubEngine(), appVersion: "9.9", protocolVersion: MCPProtocol.latest
        )
        executor.eraLog = log

        func traffic() async throws -> [String: Any] {
            let json = try JSONSerialization.jsonObject(
                with: Data(try await executor.call(name: "get_version", arguments: [:]).utf8)
            ) as? [String: Any]
            return try #require(json?["protocolTraffic"] as? [String: Any])
        }

        var reported = try await traffic()
        #expect(reported["modernRequests"] as? Int == 1)
        #expect(reported["legacyBareRequests"] as? Int == 1)
        #expect(reported["legacyHandshakes"] as? Int == 0)
        // A bare request is legacy and is *not* a blocker — stated, so a reader can't
        // mistake the one count for the other. Modern traffic was negotiated, so this
        // is a real verdict rather than an empty counter.
        #expect(reported["legacyEra"] as? String == "retirable")

        log.record(reason: .legacyHandshake, client: MCPClientIdentity(["name": "old-client"]))
        reported = try await traffic()
        #expect(reported["legacyHandshakes"] as? Int == 1)
        #expect(reported["legacyEra"] as? String == "blocked")
        let legacy = try #require(reported["legacyClients"] as? [[String: Any]])
        #expect(legacy.first?["name"] as? String == "old-client")
    }

    /// The bug this verdict is three-valued for: a counter that has seen no modern
    /// traffic must not read as "the old era can go".
    ///
    /// `MCPEraLog` keeps nothing across launches, so `legacyHandshakes == 0` is the
    /// value it holds *before it has seen anything* as well as after a clean release.
    /// The old `legacyEraRetirable: Bool` collapsed those, and answered yes to a freshly
    /// launched app serving a client — Claude Code — that negotiates by falling back and
    /// so proves nothing. Measured live at 0.0.19: 0 modern, 0 handshakes, 3 bare.
    @MainActor
    @Test func aTallyWithNoModernTrafficIsUnknownRatherThanRetirable() async throws {
        let log = MCPEraLog()
        for _ in 0..<3 { log.record(reason: .legacyBareRequest, client: nil) }
        var executor = MCPToolExecutor(
            engine: StubEngine(), appVersion: "9.9", protocolVersion: MCPProtocol.latest
        )
        executor.eraLog = log

        let json = try #require(try JSONSerialization.jsonObject(
            with: Data(try await executor.call(name: "get_version", arguments: [:]).utf8)
        ) as? [String: Any])
        let traffic = try #require(json["protocolTraffic"] as? [String: Any])

        #expect(traffic["modernRequests"] as? Int == 0)
        #expect(traffic["legacyHandshakes"] as? Int == 0)
        #expect(traffic["legacyBareRequests"] as? Int == 3)
        #expect(traffic["legacyEra"] as? String == "unknown")
        // The verdict alone doesn't say what to do next, so the reason has to.
        let reason = try #require(traffic["legacyEraReason"] as? String)
        #expect(reason.contains("per-launch"))
    }

    /// The trap the `unknown` reason exists to warn about: a legacy client that
    /// connected before this launch keeps sending traffic, and every request of it is a
    /// bare one — because the handshake happens once per connection and stateless HTTP
    /// carries nothing after it. Measured on Claude Code, which held one connection
    /// across several restarts of the app.
    ///
    /// So a busy endpoint serving an old client is indistinguishable here from an idle
    /// one, and the reason has to say what would actually produce evidence.
    @MainActor
    @Test func aLegacyClientOnAnOlderConnectionLooksLikeSilence() async throws {
        let log = MCPEraLog()
        for _ in 0 ..< 50 { log.record(reason: .legacyBareRequest, client: nil) }
        var executor = MCPToolExecutor(
            engine: StubEngine(), appVersion: "9.9", protocolVersion: MCPProtocol.latest
        )
        executor.eraLog = log

        let json = try #require(try JSONSerialization.jsonObject(
            with: Data(try await executor.call(name: "get_version", arguments: [:]).utf8)
        ) as? [String: Any])
        let traffic = try #require(json["protocolTraffic"] as? [String: Any])

        #expect(traffic["legacyBareRequests"] as? Int == 50)
        #expect(traffic["legacyEra"] as? String == "unknown", "fifty requests are still not evidence")
        let reason = try #require(traffic["legacyEraReason"] as? String)
        #expect(reason.contains("restart"), "and the reason has to say what would be")
    }

    /// An empty tally is the same question with none of the noise: nothing has been
    /// served at all, which is not a clean bill of health either.
    @MainActor
    @Test func anUntouchedTallyIsUnknown() {
        let (era, _) = ProtocolTrafficRender.verdict(
            modernRequests: 0, legacyHandshakes: 0, legacyBareRequests: 0
        )
        #expect(era == .unknown)
    }

    // MARK: End to end, through the real server

    @MainActor
    @Test func theServerRecordsTheEraOfRealRequests() async throws {
        let server = MCPServer(engine: StubEngine(), appVersion: "9.9", token: "test-token")
        defer { Task { await server.shutdown() } }
        let port = try await server.start(port: 0, announce: false)
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/mcp"))

        func post(_ body: [String: Any]) async throws -> [String: Any] {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: request)
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }

        // A legacy client, naming itself the way `initialize` does.
        _ = try await post([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": MCPProtocol.latestLegacy,
                       "clientInfo": ["name": "legacy-client", "version": "0.1"]],
        ])
        // A modern client, naming itself in `_meta`.
        _ = try await post([
            "jsonrpc": "2.0", "id": 2, "method": "tools/list",
            "params": ["_meta": [
                MCPProtocol.MetaKey.protocolVersion: MCPProtocol.latest,
                MCPProtocol.MetaKey.clientInfo: ["name": "modern-client"],
            ]],
        ])

        // Read the tally back through a *legacy* call on purpose: it needs no mirrored
        // headers, and it adds one more bare-fallback request — which must not move
        // `legacyHandshakes`, the number the retirement condition reads.
        let versionCall = try await post([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "get_version", "arguments": [:]],
        ])
        let content = try #require(
            ((versionCall["result"] as? [String: Any])?["content"] as? [[String: Any]])?
                .first?["text"] as? String
        )
        let versionJSON = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
        let traffic = try #require(versionJSON?["protocolTraffic"] as? [String: Any])

        #expect(traffic["legacyHandshakes"] as? Int == 1)
        #expect(traffic["legacyEra"] as? String == "blocked")
        let legacy = try #require(traffic["legacyClients"] as? [[String: Any]])
        #expect(legacy.first?["name"] as? String == "legacy-client")
        #expect(legacy.first?["version"] as? String == "0.1")
        let modern = try #require(traffic["modernClients"] as? [[String: Any]])
        #expect(modern.contains { $0["name"] as? String == "modern-client" })
    }
}
