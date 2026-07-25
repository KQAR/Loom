import Testing
import Foundation
import LoomSharedModels
@testable import LoomProxyCore

/// Contract for the breakpoint choke point: `BreakpointForwarder` holds matching
/// traffic on `BreakpointStore` until a resume decision arrives, applies edits to
/// the request or response, aborts on request, and — crucially — leaves
/// non-matching traffic completely untouched (including streaming).
@Suite struct BreakpointTests {
    private let url = URL(string: "https://api.example.test/v1/home")!

    private func recordingUpstream() -> BPStubUpstream { BPStubUpstream() }

    // MARK: Request phase

    @Test func requestBreakpoint_holdsThenAppliesEdit() async throws {
        let upstream = recordingUpstream()
        let store = BreakpointStore()
        let forwarder = BreakpointForwarder(base: upstream, store: store)
        store.arm(Breakpoint(match: RuleMatch(urlPattern: "*"), onRequest: true))

        async let resultTask = forwarder.forward(method: "GET", url: url, headers: [], body: nil)

        // The exchange should now be held; resume it with edits.
        let pending = try await waitForPending(store)
        #expect(pending.phase == .request)
        #expect(store.resume(pendingID: pending.id, resolution: .proceed(BreakpointEdit(
            method: "POST",
            setHeaders: [HeaderPair(name: "X-Edited", value: "1")],
            body: .replace(Data("edited".utf8))
        ))))

        _ = try await resultTask
        #expect(await upstream.lastMethod == "POST")
        #expect(await upstream.lastBody == Data("edited".utf8))
        #expect(await upstream.lastHeaders.value(named: "X-Edited") == "1")
        #expect(store.pending().isEmpty, "resumed exchange must be dropped from pending")
    }

    @Test func requestBreakpoint_abort_returns502_neverForwards() async throws {
        let upstream = recordingUpstream()
        let store = BreakpointStore()
        let forwarder = BreakpointForwarder(base: upstream, store: store)
        store.arm(Breakpoint(match: RuleMatch(urlPattern: "*"), onRequest: true))

        async let resultTask = forwarder.forward(method: "GET", url: url, headers: [], body: nil)
        let pending = try await waitForPending(store)
        #expect(store.resume(pendingID: pending.id, resolution: .abort))

        let result = try await resultTask
        #expect(result.statusCode == 502)
        #expect(await upstream.callCount == 0, "an aborted request must never reach the upstream")
    }

    // MARK: Response phase

    @Test func responseBreakpoint_editsResponse() async throws {
        let upstream = recordingUpstream()
        await upstream.setResult(ForwardResult(statusCode: 200, headers: [], body: Data("original".utf8)))
        let store = BreakpointStore()
        let forwarder = BreakpointForwarder(base: upstream, store: store)
        store.arm(Breakpoint(match: RuleMatch(urlPattern: "*"), onRequest: false, onResponse: true))

        async let resultTask = forwarder.forward(method: "GET", url: url, headers: [], body: nil)
        let pending = try await waitForPending(store)
        #expect(pending.phase == .response)
        #expect(pending.statusCode == 200)
        #expect(store.resume(pendingID: pending.id, resolution: .proceed(BreakpointEdit(
            statusCode: 503, body: .replace(Data("MAINTENANCE".utf8))
        ))))

        let result = try await resultTask
        #expect(await upstream.callCount == 1, "the response phase runs after the real upstream call")
        #expect(result.statusCode == 503)
        #expect(result.body == Data("MAINTENANCE".utf8))
    }

    // MARK: Non-matching / lifecycle

    @Test func noMatch_passthroughUntouched() async throws {
        let upstream = recordingUpstream()
        let store = BreakpointStore()
        let forwarder = BreakpointForwarder(base: upstream, store: store)
        store.arm(Breakpoint(match: RuleMatch(urlPattern: "https://other.test/*"), onRequest: true))

        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)
        #expect(await upstream.callCount == 1)
        #expect(result.body == Data("upstream".utf8))
        #expect(store.pending().isEmpty)
    }

    @Test func forwardStream_noMatch_delegatesToBase() async throws {
        let upstream = recordingUpstream()
        let store = BreakpointStore()
        let forwarder = BreakpointForwarder(base: upstream, store: store)
        // No breakpoints armed: stream should pass straight through.
        var bodies: [Data] = []
        for try await event in forwarder.forwardStream(method: "GET", url: url, headers: [], body: .bytes(nil)) {
            if case let .body(data) = event { bodies.append(data) }
        }
        #expect(bodies == [Data("upstream".utf8)])
    }

    @Test func timeout_autoProceedsUnchanged() async throws {
        let upstream = recordingUpstream()
        let store = BreakpointStore(timeout: 0.05) // fire almost immediately
        let forwarder = BreakpointForwarder(base: upstream, store: store)
        store.arm(Breakpoint(match: RuleMatch(urlPattern: "*"), onRequest: true))

        // No resume call — the timeout must release it unchanged.
        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: Data("keep".utf8))
        #expect(await upstream.callCount == 1)
        #expect(await upstream.lastBody == Data("keep".utf8))
        #expect(result.body == Data("upstream".utf8))
    }

    @Test func disarm_removesArmedBreakpoint() {
        let store = BreakpointStore()
        let bp = Breakpoint(match: RuleMatch(urlPattern: "*"))
        store.arm(bp)
        #expect(store.armed().count == 1)
        #expect(store.disarm(id: bp.id))
        #expect(!(store.disarm(id: bp.id)), "disarming a gone breakpoint returns false")
        #expect(store.armed().isEmpty)
    }

    @Test func resume_unknownPendingID_returnsFalse() {
        let store = BreakpointStore()
        #expect(!(store.resume(pendingID: UUID(), resolution: .proceed(.none))))
    }

    /// Disarming must release exchanges the breakpoint is already holding. Before
    /// this, a disarmed breakpoint left its parked connections hanging until the
    /// (minutes-long) timeout expired.
    @Test func disarm_releasesExchangesItWasHolding() async throws {
        let upstream = recordingUpstream()
        let store = BreakpointStore()
        let forwarder = BreakpointForwarder(base: upstream, store: store)
        let bp = Breakpoint(match: RuleMatch(urlPattern: "*"), onRequest: true)
        store.arm(bp)

        async let resultTask = forwarder.forward(method: "GET", url: url, headers: [], body: Data("keep".utf8))
        _ = try await waitForPending(store)

        #expect(store.disarm(id: bp.id))

        // Released unchanged, without waiting out the timeout.
        let result = try await resultTask
        #expect(await upstream.callCount == 1)
        #expect(await upstream.lastBody == Data("keep".utf8))
        #expect(result.body == Data("upstream".utf8))
        #expect(store.pending().isEmpty, "disarm must drop the held exchange")
    }

    /// Only the *matching* breakpoint's holds are released; another breakpoint's
    /// parked exchange keeps waiting.
    @Test func disarm_leavesOtherBreakpointsHoldsParked() async throws {
        let store = BreakpointStore()
        let forwarder = BreakpointForwarder(base: recordingUpstream(), store: store)
        let mine = Breakpoint(match: RuleMatch(urlPattern: "*/home"), onRequest: true)
        let other = Breakpoint(match: RuleMatch(urlPattern: "*/other"), onRequest: true)
        store.arm(mine)
        store.arm(other)

        async let held = forwarder.forward(
            method: "GET", url: URL(string: "https://api.example.test/v1/other")!, headers: [], body: nil
        )
        let pending = try await waitForPending(store)
        #expect(pending.breakpointID == other.id)

        #expect(store.disarm(id: mine.id))
        #expect(store.pending().count == 1, "disarming a different breakpoint must not release this hold")

        store.resume(pendingID: pending.id, resolution: .proceed(.none))
        _ = try await held
    }

    /// A cancelled forwarding task (the client hung up) must release the hold as an
    /// abort straight away. Otherwise the entry lingers and `list_pending` keeps
    /// advertising an exchange nobody is waiting on.
    @Test func cancellingTheForwardingTask_releasesTheHold() async throws {
        let store = BreakpointStore()
        let forwarder = BreakpointForwarder(base: recordingUpstream(), store: store)
        store.arm(Breakpoint(match: RuleMatch(urlPattern: "*"), onRequest: true))

        let task = Task { try await forwarder.forward(method: "GET", url: url, headers: [], body: nil) }
        _ = try await waitForPending(store)

        task.cancel()

        for _ in 0..<200 where !store.pending().isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(store.pending().isEmpty, "a cancelled hold must not stay pending")
        _ = try? await task.value
    }

    /// The timeout watchdog is cancelled when something else resolves the hold, so
    /// a resumed-then-aborted exchange is never also auto-proceeded afterwards.
    @Test func resolvingAHold_cancelsTheTimeoutWatchdog() async throws {
        let upstream = recordingUpstream()
        let store = BreakpointStore(timeout: 0.05)
        let forwarder = BreakpointForwarder(base: upstream, store: store)
        store.arm(Breakpoint(match: RuleMatch(urlPattern: "*"), onRequest: true))

        async let resultTask = forwarder.forward(method: "GET", url: url, headers: [], body: nil)
        let pending = try await waitForPending(store)
        #expect(store.resume(pendingID: pending.id, resolution: .abort))
        _ = try await resultTask

        // Well past the 50 ms timeout: had the watchdog survived, it would have
        // resolved `.proceed` and the request would have reached upstream.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await upstream.callCount == 0, "aborted exchange must never reach upstream")
    }

    // MARK: Helpers

    /// Poll until the forwarder has parked an exchange (the async `forward` reaches
    /// its `hold` on another task). Fails fast rather than hanging the suite.
    private func waitForPending(_ store: BreakpointStore) async throws -> PendingBreakpoint {
        for _ in 0..<200 {
            if let first = store.pending().first { return first }
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
        Issue.record("no exchange was held within the timeout")
        throw CancellationError()
    }
}

private actor BPStubUpstream: UpstreamForwarding {
    var callCount = 0
    var lastMethod: String?
    var lastURL: URL?
    var lastHeaders: [HeaderPair] = []
    var lastBody: Data?
    var result = ForwardResult(statusCode: 200, headers: [], body: Data("upstream".utf8))

    func setResult(_ result: ForwardResult) { self.result = result }

    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        callCount += 1
        lastMethod = method
        lastURL = url
        lastHeaders = headers
        lastBody = body
        return result
    }
}
