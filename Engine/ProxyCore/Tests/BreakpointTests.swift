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
        #expect(upstream.lastMethod == "POST")
        #expect(upstream.lastBody == Data("edited".utf8))
        #expect(upstream.lastHeaders.value(named: "X-Edited") == "1")
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
        #expect(upstream.callCount == 0, "an aborted request must never reach the upstream")
    }

    // MARK: Response phase

    @Test func responseBreakpoint_editsResponse() async throws {
        let upstream = recordingUpstream()
        upstream.result = ForwardResult(statusCode: 200, headers: [], body: Data("original".utf8))
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
        #expect(upstream.callCount == 1, "the response phase runs after the real upstream call")
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
        #expect(upstream.callCount == 1)
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
        #expect(upstream.callCount == 1)
        #expect(upstream.lastBody == Data("keep".utf8))
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

private final class BPStubUpstream: UpstreamForwarding, @unchecked Sendable {
    var callCount = 0
    var lastMethod: String?
    var lastURL: URL?
    var lastHeaders: [HeaderPair] = []
    var lastBody: Data?
    var result = ForwardResult(statusCode: 200, headers: [], body: Data("upstream".utf8))

    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        callCount += 1
        lastMethod = method
        lastURL = url
        lastHeaders = headers
        lastBody = body
        return result
    }
}
