import Testing
import Foundation
import Synchronization
import LoomSharedModels
@testable import LoomProxyCore

// The invariants that, if violated, corrupt what the *agent* believes.
//
// Every other test in this suite checks a feature: does map-remote rewrite the
// origin, does the ring evict, does HAR carry timings. These check the properties
// the whole design leans on — the ones no single feature owns, that nothing would
// fail loudly about if a refactor quietly broke them, and whose breakage an agent
// operating over MCP cannot see. An agent that is silently lied to about traffic
// will confidently debug the wrong thing.
//
//   I1  One write path        — UI and MCP act through the same decorated forwarder,
//                               so replay obeys rules and breakpoints like live traffic.
//   I2  Body hydration        — a captured body is retrievable no matter where it
//                               currently lives (ring / slimmed / evicted to disk).
//   I3  One rule choke point  — buffered and streaming forwarding apply rules
//                               identically; neither is a way around the other.
//   I4  Breakpoints release   — every exit path frees the held exchange exactly once.
//   I5  Replay links its flow — every replay outcome records exactly one flow
//                               pointing back at its source.
//
// Named here rather than in a doc so they fail, not rot.

// MARK: - I1 · One write path

/// `ProxyEngine` builds one forwarder chain — `BreakpointForwarder` wrapping
/// `RuleApplyingForwarder` wrapping the network client — and hands the *same*
/// instance to the proxy server and to `replay`. If replay ever grew its own path
/// (or the chain lost a decorator), an agent's `replay_flow` would bypass the rules
/// and breakpoints it just armed, and report a response the real traffic would
/// never produce. These pin the chain from the outside, through public API only.
@Suite("Invariant: one write path", .timeLimit(.minutes(1)))
struct OneWritePathInvariantTests {
    private let url = "https://api.example.test/v1/thing"

    private func makeEngine() -> (ProxyEngine, InvariantStubUpstream) {
        let upstream = InvariantStubUpstream()
        return (ProxyEngine(forwarder: upstream, caStore: InMemoryCAStore()), upstream)
    }

    private func sourceFlow(url: String) -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: url, headers: []),
            startedAt: Date(),
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date())
        )
    }

    /// A mock rule short-circuits a *replay*, not just live traffic. If replay
    /// skipped `RuleApplyingForwarder`, this would hit the network and return 200.
    @Test func replay_obeysARuleThatShortCircuits() async throws {
        let (engine, upstream) = makeEngine()
        try await engine.addRule(TrafficRule(
            name: "teapot",
            match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mock(MockResponseAction(statusCode: 418, bodyText: "teapot")))
        ))

        let replayed = try await engine.replay(flow: sourceFlow(url: url), overrides: .none)

        #expect(await upstream.callCount == 0, "a mocked replay must never reach the network")
        #expect(replayed.response?.statusCode == 418)
        #expect(replayed.appliedRules?.map(\.name) == ["teapot"],
                "the replayed flow must record which rule answered it")
    }

    /// A replay is held by an armed breakpoint, is visible in `pendingBreakpoints()`
    /// while held, and the resume edit reaches the upstream. This is also the
    /// reentrancy check: the engine actor must still serve `pendingBreakpoints` /
    /// `resumeBreakpoint` while one of its own methods is parked mid-replay —
    /// otherwise arming a breakpoint would deadlock every subsequent replay.
    @Test func replay_isHeldByABreakpoint_andTheEditReachesUpstream() async throws {
        let (engine, upstream) = makeEngine()
        try await engine.armBreakpoint(Breakpoint(match: RuleMatch(urlPattern: "*"), onRequest: true))
        let source = sourceFlow(url: url)

        let replaying = Task { try await engine.replay(flow: source, overrides: .none) }

        var held: PendingBreakpoint?
        for _ in 0..<200 {
            if let first = await engine.pendingBreakpoints().first { held = first; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let pending = try #require(held, "a replay must be holdable by an armed breakpoint")
        #expect(pending.url == url)

        try await engine.resumeBreakpoint(
            pendingID: pending.id,
            abort: false,
            edit: BreakpointEdit(method: "PUT", setHeaders: [HeaderPair(name: "X-Held", value: "1")])
        )

        let replayed = try await replaying.value
        #expect(await upstream.lastMethod == "PUT", "the breakpoint edit must reach the upstream")
        #expect(await upstream.lastHeaders.value(named: "X-Held") == "1")
        #expect(replayed.replayedFrom == source.id)
    }
}

// MARK: - I2 · Body hydration

/// A body is captured once and must stay retrievable through every place it can
/// end up: live in the ring, slimmed out of the ring by the byte budget, or aged
/// out of the ring entirely and living only in SQLite. `get_flow_detail` /
/// `diff_flows` / `replay` all read through `FlowStore.flow(id:)`, so if hydration
/// breaks at any stage an agent sees an empty body and concludes the request had
/// none — a wrong answer that looks exactly like a right one.
///
/// The individual stages have their own tests (`FlowStoreBudgetTests`,
/// `PersistedFlowReadThroughTests`); what's pinned here is the *walk* — the same
/// bytes come back at every stage, and the cheap list read never pays for them.
@Suite("Invariant: body hydration")
final class BodyHydrationInvariantTests {
    private let fileURL: URL

    init() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-invariant-\(UUID())", isDirectory: true)
            .appendingPathComponent("flows.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func completed(_ n: Int, body: Data) -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "https://api.test/\(n)", headers: []),
            startedAt: Date(timeIntervalSince1970: TimeInterval(n)),
            outcome: .completed(
                CapturedResponse(statusCode: 200, headers: [], body: body),
                at: Date(timeIntervalSince1970: TimeInterval(n) + 0.1)
            )
        )
    }

    @Test func theSameBytesComeBack_inTheRing_slimmed_andEvicted() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        // capacity 3 so the fourth insert evicts; budget 1000 so the second slims.
        let store = FlowStore(capacity: 3, bodyBudget: 1000, persistence: persistence)
        let payload = Data(repeating: 0xAB, count: 600)
        let subject = completed(1, body: payload)

        // Stage 1 — live in the ring, body in memory.
        await store.upsert(subject)
        #expect(await store.flow(id: subject.id)?.response?.body == payload)
        #expect(await store.recent(limit: 3).first?.response?.body == payload)

        // Stage 2 — slimmed by the byte budget: gone from the ring, still on disk.
        await store.upsert(completed(2, body: payload))
        let ringCopy = await store.recent(limit: 3).first { $0.id == subject.id }
        #expect(ringCopy?.response?.body == nil, "a slimmed flow holds no body in memory")
        #expect(await store.flow(id: subject.id)?.response?.body == payload,
                "…but a detail read hydrates the identical bytes back")

        // Stage 3 — evicted from the ring entirely: only SQLite has it now.
        await store.upsert(completed(3, body: payload))
        await store.upsert(completed(4, body: payload))
        #expect(await store.recent(limit: 3).contains { $0.id == subject.id } == false, "aged out of the ring")
        #expect(await store.flow(id: subject.id)?.response?.body == payload,
                "read-through must still resolve the id an agent legitimately holds")
    }

    /// The other half of the invariant: hydration is *opt-in*, and exactly which
    /// reads opt in is the contract. The list read must never quietly pull bodies
    /// off disk — that's the difference between rendering 2000 rows and loading
    /// gigabytes to render 2000 rows — while the detail and export reads must.
    @Test func onlyDetailAndExportReadsHydrate_neverTheListRead() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        // Budget of 1 byte: the flow is slimmed the moment it lands.
        let store = FlowStore(capacity: 10, bodyBudget: 1, persistence: persistence)
        let subject = completed(1, body: Data(repeating: 0xCD, count: 600))
        await store.upsert(subject)

        let listed = await store.recent(limit: 10).first { $0.id == subject.id }
        #expect(listed?.response?.body == nil, "the list read stays body-free")

        let exported = await store.recentHydrated(limit: 10).first { $0.id == subject.id }
        #expect(exported?.response?.body?.count == 600, "the export read (HAR) hydrates")
        #expect(await store.flow(id: subject.id)?.response?.body?.count == 600, "so does the detail read")
    }
}

// MARK: - I3 · One rule choke point

/// `forward` (buffered) is documented as a *fold* over `forwardStream` — one
/// production path, so a rule cannot apply on one and not the other. A second
/// implementation of buffered forwarding is the easy refactor that would break
/// this: rules would apply to streaming traffic and silently not to the buffered
/// paths (replay, held exchanges, body-rewriting rules).
@Suite("Invariant: one rule choke point")
struct RuleChokePointInvariantTests {
    private let url = URL(string: "https://api.example.test/v1/thing")!

    private func forwarder(_ rules: [TrafficRule], base: UpstreamForwarding) -> RuleApplyingForwarder {
        RuleApplyingForwarder(
            base: base,
            rules: RulesConfig(state: RulesState(enabled: true, rules: rules), fileURL: nil)
        )
    }

    @Test func bufferedAndStreamingForwarding_agree() async throws {
        let rules = [
            TrafficRule(
                name: "stamp",
                match: RuleMatch(urlPattern: "*"),
                actions: RuleActions(rewriteResponse: ResponseRewriteAction(
                    statusCode: 201, setHeaders: [HeaderPair(name: "X-Rule", value: "hit")]
                ))
            )
        ]

        let buffered = try await forwarder(rules, base: InvariantStubUpstream())
            .forward(method: "GET", url: url, headers: [], body: nil)
        let streamed = try await forwarder(rules, base: InvariantStubUpstream())
            .forwardStream(method: "GET", url: url, headers: [], body: .bytes(nil))
            .collect()

        #expect(buffered.statusCode == streamed.statusCode)
        #expect(buffered.headers == streamed.headers)
        #expect(buffered.body == streamed.body)
        #expect(streamed.statusCode == 201, "the rule applied at all (guards against both paths being no-ops)")
    }

    /// A short-circuiting rule must reach the same verdict either way — otherwise
    /// "mock this endpoint" would hold for live traffic but let a replay through to
    /// the real upstream.
    @Test func shortCircuitAgrees_andNeitherPathContactsUpstream() async throws {
        let rules = [
            TrafficRule(
                name: "blocked",
                match: RuleMatch(urlPattern: "*"),
                actions: RuleActions(route: .block)
            )
        ]
        let bufferedUpstream = InvariantStubUpstream()
        let streamedUpstream = InvariantStubUpstream()

        let buffered = try await forwarder(rules, base: bufferedUpstream)
            .forward(method: "GET", url: url, headers: [], body: nil)
        let streamed = try await forwarder(rules, base: streamedUpstream)
            .forwardStream(method: "GET", url: url, headers: [], body: .bytes(nil))
            .collect()

        #expect(buffered.statusCode == streamed.statusCode)
        #expect(await bufferedUpstream.callCount == 0)
        #expect(await streamedUpstream.callCount == 0)
    }
}

// MARK: - I4 · Breakpoints always release

/// A breakpoint parks a *live client connection* on a continuation. Every way out
/// must release it exactly once: resume, abort, disarm, timeout, and client
/// hang-up. A missed release hangs a real connection for the whole timeout (and
/// leaves `list_pending` advertising an exchange nobody is waiting on); a double
/// release traps on the checked continuation and takes the process down.
///
/// Individual exits have their own tests in `BreakpointTests`. This is the table:
/// no exit is exempt, and the store is empty afterwards in every case.
@Suite("Invariant: breakpoints always release", .timeLimit(.minutes(1)))
struct BreakpointReleaseInvariantTests {
    private let url = URL(string: "https://api.example.test/v1/home")!

    enum Exit: String, CaseIterable, Sendable {
        case resume, abort, disarm, timeout, clientHangUp
    }

    @Test(arguments: Exit.allCases)
    func everyExitReleasesTheHold(_ exit: Exit) async throws {
        // Only the timeout case gets a short watchdog; the others use the real one
        // so a leaked hold can't be masked by an auto-proceed.
        let store = BreakpointStore(timeout: exit == .timeout ? 0.05 : 300)
        let forwarder = BreakpointForwarder(base: InvariantStubUpstream(), store: store)
        let breakpoint = Breakpoint(match: RuleMatch(urlPattern: "*"), onRequest: true)
        store.arm(breakpoint)

        let done = Signal()
        let forwarding = Task { () -> ForwardResult in
            defer { done.signal() }
            return try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)
        }

        if exit != .timeout {
            // The timeout case may resolve before we ever observe the hold; every
            // other exit needs the exchange parked first.
            let pending = try #require(await Self.waitForPending(store), "the exchange never parked")
            switch exit {
            case .resume: #expect(store.resume(pendingID: pending.id, resolution: .proceed(.none)))
            case .abort: #expect(store.resume(pendingID: pending.id, resolution: .abort))
            case .disarm: #expect(store.disarm(id: breakpoint.id))
            case .clientHangUp: forwarding.cancel()
            case .timeout: break
            }
        }

        // The point of the invariant: the call finishes rather than hanging. Checked
        // against a short deadline so a leak fails in a second — letting it run into
        // the suite's time limit instead would kill and restart the whole test
        // process, taking the rest of the run's results with it.
        #expect(await done.wait(seconds: 2), "\(exit.rawValue) never released the exchange — the forward hung")
        // Read `pending` before cancelling: cancellation would itself release the
        // hold and paper over exactly the leak this is looking for.
        #expect(store.pending().isEmpty, "\(exit.rawValue) left the exchange held")
        forwarding.cancel()
    }

    /// Resume, disarm and timeout can all fire at once on the same hold (an
    /// operator resuming just as the watchdog trips). Exactly one must win: a
    /// second `resume` on a `CheckedContinuation` is a hard crash, so this test
    /// failing usually means the whole test process dying.
    @Test func concurrentResolutions_resolveExactlyOnce() async throws {
        let store = BreakpointStore(timeout: 0.05)
        let forwarder = BreakpointForwarder(base: InvariantStubUpstream(), store: store)
        let breakpoint = Breakpoint(match: RuleMatch(urlPattern: "*"), onRequest: true)
        store.arm(breakpoint)

        // Subscribe *before* forwarding. `pending()` is a snapshot, and the 50 ms
        // watchdog can empty it before a poll ever looks — a race this test created
        // for itself, and the flake in #116. The announcement stream buffers, so the
        // observation cannot be outrun however slow the machine is.
        //
        // If the watchdog then wins the race below, that is a legitimate outcome and
        // not a failure: the invariant is that *exactly one* resolver claims the
        // hold and the exchange is released once — not that `resume` is the winner.
        let announcements = store.pendingStream()

        let done = Signal()
        let forwarding = Task { () -> ForwardResult in
            defer { done.signal() }
            return try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)
        }
        let pending = try #require(await Self.firstParked(announcements), "the exchange never parked")

        // Three racing resolvers plus the watchdog already ticking. `disarm` joins
        // the race but isn't counted: its Bool answers "was a breakpoint removed",
        // not "did I release the hold" — only `resume` reports that.
        async let a = Task.detached { store.resume(pendingID: pending.id, resolution: .proceed(.none)) }.value
        async let b = Task.detached { store.resume(pendingID: pending.id, resolution: .abort) }.value
        async let c: Void = Task.detached { _ = store.disarm(id: breakpoint.id) }.value
        let claimed = await [a, b].filter { $0 }
        await c

        #expect(await done.wait(seconds: 2), "the raced hold was never released")
        #expect(claimed.count <= 1, "two resolvers both claimed the same hold")
        #expect(store.pending().isEmpty)
        forwarding.cancel()
    }

    /// The first exchange announced as parked, or nil if none arrives in time.
    ///
    /// `stream` must be obtained *before* the forward starts: `pending()` is a
    /// snapshot a short watchdog can empty before a poll ever looks, while the
    /// announcement is buffered and so cannot be outrun (#116).
    ///
    /// Bounded on purpose. Awaiting the stream alone suspends forever when the
    /// exchange never parks, which would turn a real bug from a two-second failure
    /// into this suite's one-minute limit killing the test process and taking the
    /// rest of the run's results with it.
    private static func firstParked(
        _ stream: AsyncStream<PendingBreakpoint>, within seconds: Double = 2
    ) async -> PendingBreakpoint? {
        await withTaskGroup(of: PendingBreakpoint?.self) { group in
            group.addTask {
                for await parked in stream { return parked }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Poll for a parked exchange.
    ///
    /// Only safe when the store's watchdog **cannot** outrun the poll — `pending()`
    /// is a snapshot, so a short timeout can release the hold before this ever sees
    /// it (#116). Callers with a short watchdog must use `firstParked` instead.
    private static func waitForPending(_ store: BreakpointStore) async -> PendingBreakpoint? {
        for _ in 0..<200 {
            if let first = store.pending().first { return first }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }

}

/// "The forwarding task returned" as a pollable flag.
///
/// The obvious spelling — race `await task.value` against a sleep in a task group
/// — deadlocks precisely when the invariant is broken: the group joins its
/// children before returning, cancelling a child doesn't interrupt `task.value`,
/// and the hung forward never completes. The test would then hang until the
/// suite's time-limit trait kills and restarts the whole test process, discarding
/// every other result in the run. Polling a flag never touches the stuck task.
private final class Signal: Sendable {
    private let raised = Mutex(false)

    func signal() {
        raised.withLock { $0 = true }
    }

    private var isRaised: Bool {
        raised.withLock { $0 }
    }

    func wait(seconds: Double) async -> Bool {
        for _ in 0..<Int(seconds * 200) {
            if isRaised { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return isRaised
    }
}

// MARK: - I5 · Replay links its flow

/// Every replay — succeeded, failed, or answered by a rule — records exactly one
/// new flow whose `replayedFrom` points at its source. That link is what makes
/// `diff_flows` work with only a `base` id, and it's the agent's sole evidence
/// that its edit was the thing that changed the response. A replay that records
/// nothing (or records an unlinked flow) leaves the loop unclosable.
@Suite("Invariant: replay links its flow", .timeLimit(.minutes(1)))
struct ReplayLinkInvariantTests {
    private func sourceFlow() -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "https://api.example.test/v1/thing", headers: []),
            startedAt: Date(),
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date())
        )
    }

    @Test func replay_recordsALinkedFlow_evenWhileCaptureIsPaused() async throws {
        let engine = ProxyEngine(forwarder: InvariantStubUpstream(), caStore: InMemoryCAStore())
        // Pausing capture stops *observed* traffic being stored. An explicit action
        // is not observed traffic: if the pause swallowed it, an agent would replay,
        // get a result, and then find no flow to diff against.
        await engine.setRecording(false)
        let source = sourceFlow()

        let replayed = try await engine.replay(flow: source, overrides: .none)

        let stored = await engine.recentFlows(limit: 10)
        #expect(stored.count == 1, "exactly one flow recorded")
        #expect(stored.first?.id == replayed.id)
        #expect(stored.first?.id != source.id, "a replay is a new flow, not an overwrite of its source")
        #expect(stored.first?.replayedFrom == source.id)
    }

    @Test func replay_answeredByARule_stillLinks() async throws {
        let engine = ProxyEngine(forwarder: InvariantStubUpstream(), caStore: InMemoryCAStore())
        try await engine.addRule(TrafficRule(
            name: "mocked",
            match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mock(MockResponseAction(statusCode: 503)))
        ))
        let source = sourceFlow()

        let replayed = try await engine.replay(flow: source, overrides: .none)

        #expect(replayed.replayedFrom == source.id)
        #expect(await engine.flow(id: replayed.id)?.replayedFrom == source.id,
                "the link must survive into the store, not just the returned value")
    }

    /// The failure direction: a replay that can't reach upstream throws, and still
    /// leaves a linked flow behind. Without it the agent sees an error and no
    /// record — the one case where it most needs the record.
    @Test func replay_thatFails_stillLinks() async throws {
        let engine = ProxyEngine(forwarder: FailingUpstream(), caStore: InMemoryCAStore())
        let source = sourceFlow()

        await #expect(throws: ProxyControlError.self) {
            _ = try await engine.replay(flow: source, overrides: .none)
        }

        let stored = await engine.recentFlows(limit: 10)
        #expect(stored.count == 1)
        #expect(stored.first?.replayedFrom == source.id)
        if case .failed = stored.first?.outcome {} else { Issue.record("expected a failed replay flow") }
    }
}

// MARK: - Shared stubs

/// Records what reached "upstream" and answers 200. Shared by the suites above so
/// each one asserts against the same deterministic edge of the world.
private actor InvariantStubUpstream: UpstreamForwarding {
    var callCount = 0
    var lastMethod: String?
    var lastURL: URL?
    var lastHeaders: [HeaderPair] = []
    var lastBody: Data?

    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        callCount += 1
        lastMethod = method
        lastURL = url
        lastHeaders = headers
        lastBody = body
        return ForwardResult(statusCode: 200, headers: [HeaderPair(name: "X-Upstream", value: "1")], body: Data("upstream".utf8))
    }
}

private struct FailingUpstream: UpstreamForwarding {
    struct Unreachable: Error {}
    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        throw Unreachable()
    }
}
