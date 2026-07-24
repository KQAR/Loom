import Testing
import Foundation
import NIOCore
import NIOEmbedded
@testable import LoomProxyCore
import LoomSharedModels

/// Regression guard for the "failed flow drops its rule hits" bug: a rule (e.g.
/// map-remote to a dead upstream) applies, the connection then fails before any
/// response head, and the captured flow must still record `appliedRules` — the
/// `.metadata` event is emitted before the network call, so it survives the error.
@Suite struct AppliedRulesOnFailureTests {
    private let url = URL(string: "https://api.example.test/v1/home")!

    /// A base forwarder that always fails to reach upstream.
    private final class ThrowingUpstream: UpstreamForwarding, @unchecked Sendable {
        struct Boom: Error {}
        func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
            throw Boom()
        }
    }

    private func forwarder(_ rules: [TrafficRule]) -> RuleApplyingForwarder {
        RuleApplyingForwarder(
            base: ThrowingUpstream(),
            rules: RulesConfig(state: RulesState(enabled: true, rules: rules), fileURL: nil)
        )
    }

    /// Drain a forwardStream, returning the rules seen via `.metadata` and whether it threw.
    private func drain(_ forwarder: RuleApplyingForwarder) async -> (applied: [AppliedRule], threw: Bool) {
        var applied: [AppliedRule] = []
        var threw = false
        do {
            for try await event in forwarder.forwardStream(method: "GET", url: url, headers: [], body: .bytes(nil)) {
                if case let .metadata(rules) = event { applied = rules }
            }
        } catch { threw = true }
        return (applied, threw)
    }

    @Test func mapRemote_upstreamFails_emitsRuleMetadataBeforeError() async {
        let rule = TrafficRule(
            name: "to local", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mapRemote(MapRemoteAction(destination: "http://127.0.0.1:1")))
        )
        let (applied, threw) = await drain(forwarder([rule]))
        #expect(threw, "a dead upstream must still surface as an error")
        #expect(applied.map(\.name) == ["to local"],
                "rule hits must be emitted before the failure so a failed flow can record them")
    }

    @Test func responseRewrite_upstreamFails_emitsRuleMetadata() async {
        // A response rewrite forces the buffering branch; the fix must cover it too.
        let rule = TrafficRule(
            name: "force 503", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(rewriteResponse: ResponseRewriteAction(statusCode: 503))
        )
        let (applied, threw) = await drain(forwarder([rule]))
        #expect(threw)
        #expect(applied.map(\.name) == ["force 503"])
    }

    @Test func noRule_upstreamFails_emitsNoMetadata() async {
        // No rule matched → no `.metadata` event → a passthrough stream is byte-identical
        // to before (no extra event on the hot path).
        var sawMetadata = false
        var threw = false
        do {
            for try await event in forwarder([]).forwardStream(method: "GET", url: url, headers: [], body: .bytes(nil)) {
                if case .metadata = event { sawMetadata = true }
            }
        } catch { threw = true }
        #expect(threw)
        #expect(!sawMetadata)
    }

    /// End-to-end: the failed flow the store records carries `appliedRules`.
    @Test func streamRelay_recordsAppliedRules_onFailedFlow() async throws {
        let store = FlowStore()
        let flowID = UUID()
        let rule = AppliedRule(id: UUID(), name: "to local")

        // A stream that emits rule metadata, then fails before any response head —
        // exactly what map-remote to a dead upstream produces.
        struct Boom: Error {}
        let (stream, cont) = AsyncThrowingStream<UpstreamResponseEvent, Error>.makeStream()
        cont.yield(.metadata(appliedRules: [rule]))
        cont.finish(throwing: Boom())

        let channel = EmbeddedChannel()
        // Activate the channel — StreamRelay bails on the first event if !isActive.
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        await StreamRelay.relay(
            stream: stream, channel: channel, keepAlive: false, flowID: flowID,
            request: CapturedRequest(method: "GET", url: url.absoluteString, headers: [], body: nil),
            startedAt: Date(), sourceApp: nil, sourceDevice: nil, store: store
        )

        let flow = await store.flow(id: flowID)
        #expect(flow?.appliedRules?.map(\.name) == ["to local"],
                "a failed flow must still carry the rules that acted on it")
        if case .failed = flow?.outcome {} else { Issue.record("expected a failed outcome") }
        _ = try? channel.finish()
    }

    /// Replay goes through `forwardStream` too (step 2), so a replay that matches a
    /// rule but fails to connect still records the rule on its failed flow.
    @Test func replay_ruleMatches_upstreamFails_failedFlowCarriesAppliedRules() async throws {
        let engine = ProxyEngine(forwarder: ThrowingUpstream(), caStore: InMemoryCAStore())
        try await engine.addRule(TrafficRule(
            name: "to local", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mapRemote(MapRemoteAction(destination: "http://127.0.0.1:1")))
        ))
        let source = Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: url.absoluteString, headers: []),
            startedAt: Date(),
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date())
        )

        await #expect(throws: ProxyControlError.self) {
            _ = try await engine.replay(flow: source, overrides: .none)
        }

        let recent = await engine.recentFlows(limit: 1)
        #expect(recent.first?.appliedRules?.map(\.name) == ["to local"])
        if case .failed = recent.first?.outcome {} else { Issue.record("expected a failed replay flow") }
    }

    /// A base that emits rule metadata, then fails — i.e. rules matched below the
    /// breakpoint but the upstream is dead.
    private final class MetadataThenFailUpstream: UpstreamForwarding, @unchecked Sendable {
        struct Boom: Error {}
        let rule: AppliedRule
        init(rule: AppliedRule) { self.rule = rule }
        func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult { throw Boom() }
        func forwardStream(method: String, url: URL, headers: [HeaderPair], body: RequestBody) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
            let rule = self.rule
            return AsyncThrowingStream { continuation in
                continuation.yield(.metadata(appliedRules: [rule]))
                continuation.finish(throwing: Boom())
            }
        }
    }

    /// A held (breakpoint-matched) exchange that fails upstream after resume must still
    /// surface the rule metadata — the breakpoint path forwards `.metadata` before the
    /// error instead of burying it in a buffered result.
    @Test func breakpoint_heldRequest_upstreamFails_stillEmitsMetadata() async throws {
        let rule = AppliedRule(id: UUID(), name: "to local")
        let store = BreakpointStore()
        let forwarder = BreakpointForwarder(base: MetadataThenFailUpstream(rule: rule), store: store)
        store.arm(Breakpoint(match: RuleMatch(urlPattern: "*"), onRequest: true))

        let consume = Task { () -> (applied: [AppliedRule], threw: Bool) in
            var applied: [AppliedRule] = []
            do {
                for try await event in forwarder.forwardStream(method: "GET", url: url, headers: [], body: .bytes(nil)) {
                    if case let .metadata(rules) = event { applied = rules }
                }
                return (applied, false)
            } catch { return (applied, true) }
        }

        // Release the held request unchanged once it parks.
        for _ in 0..<200 {
            if let pending = store.pending().first {
                #expect(store.resume(pendingID: pending.id, resolution: .proceed(.none)))
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        let (applied, threw) = await consume.value
        #expect(threw, "a dead upstream must still surface as an error")
        #expect(applied.map(\.name) == ["to local"], "a held exchange's rule hits survive an upstream failure")
    }
}
