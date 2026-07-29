import Testing
import Foundation
import LoomSharedModels
@testable import LoomProxyCore

/// Contract for the breakpoint choke point: `BreakpointForwarder` holds matching
/// traffic on `BreakpointStore` until a resume decision arrives, applies edits to
/// the request or response, aborts on request, and — crucially — leaves
/// non-matching traffic completely untouched (including streaming).
///
/// Time-limited as a whole: every wait in here is for an exchange to park or
/// release, and if one never does, the honest outcome is a failed test naming it —
/// not a run that hangs until the CI job is killed. Several helpers used to carry
/// their own poll budget purely to avoid that, which made them fail early on a
/// loaded machine instead.
@Suite(.timeLimit(.minutes(2))) struct BreakpointTests {
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
        // A long timeout, deliberately: the abort must win, and nothing here waits
        // for the deadline any more, so making it generous costs nothing.
        //
        // This test used to race the clock twice — abort had to beat a 500 ms
        // watchdog, then the test slept 800 ms to "prove" the watchdog was
        // cancelled. Widening that margin only lowered the odds of a flake (it has
        // gone red on `main` at 50 ms and again after); it never made the assertion
        // sound, because sleeping past a deadline and seeing nothing is not proof
        // that a task was cancelled. The store now reports both directly.
        let store = BreakpointStore(timeout: 30)
        let forwarder = BreakpointForwarder(base: upstream, store: store)
        store.arm(Breakpoint(match: RuleMatch(urlPattern: "*"), onRequest: true))

        // Subscribe before forwarding: `pending()` is a snapshot the watchdog can
        // empty first, the announcement stream is buffered and cannot be missed.
        let announcements = store.pendingStream()
        async let resultTask = forwarder.forward(method: "GET", url: url, headers: [], body: nil)
        let pending = try #require(await firstParked(announcements), "the exchange never parked")
        let watchdog = try #require(store.mostRecentWatchdog, "the hold should have armed a watchdog")

        #expect(store.resume(pendingID: pending.id, resolution: .abort))
        _ = try await resultTask

        // Awaiting the watchdog is exact: a cancelled one returns as soon as its
        // sleep throws, so this finishes in microseconds rather than waiting out a
        // 30 s deadline. If the abort had failed to cancel it, this would hang —
        // which the suite's time limit turns into a named failure.
        await watchdog.value
        #expect(store.timeoutResolutions == 0, "the watchdog must not have auto-proceeded the aborted hold")
        #expect(await upstream.callCount == 0, "aborted exchange must never reach upstream")
    }

    /// The push half of the poll model: a parked exchange is announced on
    /// `pendingStream()` the moment it is parked, so `wait_for_pending` can be a wait
    /// instead of a `list_pending` loop. It must fire *while the exchange is still
    /// held* — a notification that arrives after the hold was resolved is useless.
    @Test func parkingAnExchange_announcesItOnThePendingStream() async throws {
        let store = BreakpointStore()
        let forwarder = BreakpointForwarder(base: recordingUpstream(), store: store)
        store.arm(Breakpoint(match: RuleMatch(urlPattern: "*"), onRequest: true))

        var iterator = store.pendingStream().makeAsyncIterator()
        async let resultTask = forwarder.forward(method: "GET", url: url, headers: [], body: nil)

        let announced = try #require(await iterator.next())
        #expect(announced.url == url.absoluteString)
        #expect(store.pending().map(\.id) == [announced.id],
                "the announcement must arrive while the exchange is still resumable")

        #expect(store.resume(pendingID: announced.id, resolution: .proceed(.none)))
        _ = try await resultTask
    }

    /// Two subscribers both hear about a hold, and a subscriber that goes away stops
    /// costing anything — the same fan-out contract as the flow stream.
    @Test func pendingStream_fansOutAndDropsTerminatedSubscribers() async throws {
        let store = BreakpointStore()
        let forwarder = BreakpointForwarder(base: recordingUpstream(), store: store)
        store.arm(Breakpoint(match: RuleMatch(urlPattern: "*"), onRequest: true))

        var first = store.pendingStream().makeAsyncIterator()
        var second = store.pendingStream().makeAsyncIterator()

        async let resultTask = forwarder.forward(method: "GET", url: url, headers: [], body: nil)
        let a = try #require(await first.next())
        let b = try #require(await second.next())
        #expect(a.id == b.id)

        #expect(store.resume(pendingID: a.id, resolution: .proceed(.none)))
        _ = try await resultTask
    }

    /// `cancel` writes a "cancelled before it parked" marker whenever it finds no
    /// held entry — but "no held entry" has a second meaning it cannot tell apart:
    /// *already resolved*, by resume, disarm or the watchdog. A marker written then
    /// has no consumer, because the `hold` that would have eaten it is already past
    /// the point where it looks, so the id stays for the life of the process. The
    /// pairing that produces it — a client hanging up just as an operator resumes —
    /// is ordinary for a hold that pins a live connection, and this is the engine's
    /// one uncapped collection.
    ///
    /// The window is narrow, so hammer it rather than trying to hit it once.
    @Test func cancellingAroundAResolution_leavesNoMarkerBehind() async throws {
        let store = BreakpointStore(timeout: 300)
        // Subscribed once, before any hold starts: announcements are buffered, so
        // consuming one per iteration can't be outrun (#116).
        //
        // This used to spin `for _ in 0..<2000 where !parked { await Task.yield() }`
        // per iteration — up to a million yields. `Task.yield()` hands off within
        // the cooperative pool without giving up wall-clock time, so on a loaded
        // machine the `hold` task could simply not be scheduled inside the budget
        // and the require failed. A spin gets *worse* as the box gets busier, which
        // is exactly backwards for CI. The suite's time limit now turns a genuine
        // stall into a failure instead of the hang the budget was there to prevent.
        var announcements = store.pendingStream().makeAsyncIterator()

        for _ in 0..<500 {
            let info = PendingBreakpoint(
                breakpointID: UUID(), phase: .request,
                method: "GET", url: url.absoluteString, requestHeaders: []
            )
            let holding = Task { await store.hold(info) }

            let parked = await announcements.next()
            try #require(parked?.id == info.id, "the exchange never parked")

            // Resolve and cancel back to back, so the cancellation lands while
            // `hold` is on its way out and `held` no longer holds the entry.
            store.resume(pendingID: info.id, resolution: .abort)
            holding.cancel()
            _ = await holding.value
        }

        #expect(store.cancelledBeforeParkCount == 0,
                "a cancelled-before-park marker outlived the hold that owned it")
    }

    // MARK: Helpers

    /// The first exchange announced as parked, or nil if none arrives in time.
    ///
    /// `stream` must be obtained *before* the forward starts: `pending()` is a
    /// snapshot a short watchdog can empty before a poll ever looks, while the
    /// announcement is buffered and so cannot be outrun (#116).
    ///
    /// Bounded on purpose. Awaiting the stream alone suspends forever when the
    /// exchange never parks — and this suite has no time limit, so that would hang
    /// the whole run rather than fail a test.
    private func firstParked(
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
    /// Only safe when the store's watchdog **cannot** outrun the poll — every caller
    /// here uses the default 300 s timeout. `pending()` is a snapshot, so a short
    /// timeout can release the hold before this ever sees it (#116); a test with a
    /// short watchdog must use `firstParked` instead.
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
