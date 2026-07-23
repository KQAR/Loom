import XCTest
import SharedModels
@testable import ProxyCore

/// Contract for the breakpoint choke point: `BreakpointForwarder` holds matching
/// traffic on `BreakpointStore` until a resume decision arrives, applies edits to
/// the request or response, aborts on request, and — crucially — leaves
/// non-matching traffic completely untouched (including streaming).
final class BreakpointTests: XCTestCase {
    private let url = URL(string: "https://api.example.test/v1/home")!

    private func recordingUpstream() -> BPStubUpstream { BPStubUpstream() }

    // MARK: Request phase

    func test_requestBreakpoint_holdsThenAppliesEdit() async throws {
        let upstream = recordingUpstream()
        let store = BreakpointStore()
        let forwarder = BreakpointForwarder(base: upstream, store: store)
        store.arm(Breakpoint(match: RuleMatch(urlPattern: "*"), onRequest: true))

        async let resultTask = forwarder.forward(method: "GET", url: url, headers: [], body: nil)

        // The exchange should now be held; resume it with edits.
        let pending = try await waitForPending(store)
        XCTAssertEqual(pending.phase, .request)
        XCTAssertTrue(store.resume(pendingID: pending.id, resolution: .proceed(BreakpointEdit(
            method: "POST",
            setHeaders: [HeaderPair(name: "X-Edited", value: "1")],
            body: .replace(Data("edited".utf8))
        ))))

        _ = try await resultTask
        XCTAssertEqual(upstream.lastMethod, "POST")
        XCTAssertEqual(upstream.lastBody, Data("edited".utf8))
        XCTAssertEqual(upstream.lastHeaders.value(named: "X-Edited"), "1")
        XCTAssertTrue(store.pending().isEmpty, "resumed exchange must be dropped from pending")
    }

    func test_requestBreakpoint_abort_returns502_neverForwards() async throws {
        let upstream = recordingUpstream()
        let store = BreakpointStore()
        let forwarder = BreakpointForwarder(base: upstream, store: store)
        store.arm(Breakpoint(match: RuleMatch(urlPattern: "*"), onRequest: true))

        async let resultTask = forwarder.forward(method: "GET", url: url, headers: [], body: nil)
        let pending = try await waitForPending(store)
        XCTAssertTrue(store.resume(pendingID: pending.id, resolution: .abort))

        let result = try await resultTask
        XCTAssertEqual(result.statusCode, 502)
        XCTAssertEqual(upstream.callCount, 0, "an aborted request must never reach the upstream")
    }

    // MARK: Response phase

    func test_responseBreakpoint_editsResponse() async throws {
        let upstream = recordingUpstream()
        upstream.result = ForwardResult(statusCode: 200, headers: [], body: Data("original".utf8))
        let store = BreakpointStore()
        let forwarder = BreakpointForwarder(base: upstream, store: store)
        store.arm(Breakpoint(match: RuleMatch(urlPattern: "*"), onRequest: false, onResponse: true))

        async let resultTask = forwarder.forward(method: "GET", url: url, headers: [], body: nil)
        let pending = try await waitForPending(store)
        XCTAssertEqual(pending.phase, .response)
        XCTAssertEqual(pending.statusCode, 200)
        XCTAssertTrue(store.resume(pendingID: pending.id, resolution: .proceed(BreakpointEdit(
            statusCode: 503, body: .replace(Data("MAINTENANCE".utf8))
        ))))

        let result = try await resultTask
        XCTAssertEqual(upstream.callCount, 1, "the response phase runs after the real upstream call")
        XCTAssertEqual(result.statusCode, 503)
        XCTAssertEqual(result.body, Data("MAINTENANCE".utf8))
    }

    // MARK: Non-matching / lifecycle

    func test_noMatch_passthroughUntouched() async throws {
        let upstream = recordingUpstream()
        let store = BreakpointStore()
        let forwarder = BreakpointForwarder(base: upstream, store: store)
        store.arm(Breakpoint(match: RuleMatch(urlPattern: "https://other.test/*"), onRequest: true))

        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)
        XCTAssertEqual(upstream.callCount, 1)
        XCTAssertEqual(result.body, Data("upstream".utf8))
        XCTAssertTrue(store.pending().isEmpty)
    }

    func test_forwardStream_noMatch_delegatesToBase() async throws {
        let upstream = recordingUpstream()
        let store = BreakpointStore()
        let forwarder = BreakpointForwarder(base: upstream, store: store)
        // No breakpoints armed: stream should pass straight through.
        var bodies: [Data] = []
        for try await event in forwarder.forwardStream(method: "GET", url: url, headers: [], body: nil) {
            if case let .body(data) = event { bodies.append(data) }
        }
        XCTAssertEqual(bodies, [Data("upstream".utf8)])
    }

    func test_timeout_autoProceedsUnchanged() async throws {
        let upstream = recordingUpstream()
        let store = BreakpointStore(timeout: 0.05) // fire almost immediately
        let forwarder = BreakpointForwarder(base: upstream, store: store)
        store.arm(Breakpoint(match: RuleMatch(urlPattern: "*"), onRequest: true))

        // No resume call — the timeout must release it unchanged.
        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: Data("keep".utf8))
        XCTAssertEqual(upstream.callCount, 1)
        XCTAssertEqual(upstream.lastBody, Data("keep".utf8))
        XCTAssertEqual(result.body, Data("upstream".utf8))
    }

    func test_disarm_removesArmedBreakpoint() {
        let store = BreakpointStore()
        let bp = Breakpoint(match: RuleMatch(urlPattern: "*"))
        store.arm(bp)
        XCTAssertEqual(store.armed().count, 1)
        XCTAssertTrue(store.disarm(id: bp.id))
        XCTAssertFalse(store.disarm(id: bp.id), "disarming a gone breakpoint returns false")
        XCTAssertTrue(store.armed().isEmpty)
    }

    func test_resume_unknownPendingID_returnsFalse() {
        let store = BreakpointStore()
        XCTAssertFalse(store.resume(pendingID: UUID(), resolution: .proceed(.none)))
    }

    // MARK: Helpers

    /// Poll until the forwarder has parked an exchange (the async `forward` reaches
    /// its `hold` on another task). Fails fast rather than hanging the suite.
    private func waitForPending(_ store: BreakpointStore) async throws -> PendingBreakpoint {
        for _ in 0..<200 {
            if let first = store.pending().first { return first }
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
        XCTFail("no exchange was held within the timeout")
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
