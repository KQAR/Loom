import ComposableArchitecture
import Foundation
import LoomSharedModels
import Testing

@testable import AppFeature

/// `displayFlows` has two writers now, and this is the argument that they agree.
///
/// The full rebuild filters the whole window; the incremental fold applies only what a
/// batch carried, and declines (returning to the rebuild) for the cases it cannot order
/// correctly. That is a cached list with a second writer — exactly the shape
/// `refreshVisibleFlows` documents as rendering wrongly and silently — so the guard is
/// not "the fast path looks right" but "the fast path produces the same list, element
/// for element, under every transition the capture can produce".
///
/// The transitions that matter are the ones about *position*, because appending is only
/// correct at the end of the list:
/// - an exchange completing (already shown, updated in place),
/// - an exchange failing under `.errors` (not shown, becomes shown, and belongs at its
///   own place in the capture rather than at the end),
/// - attribution backfilled under `.app` (same shape),
/// - a slow exchange completing after a faster one started (the batch's own order and
///   the capture's order differ),
/// - the display cap trimming mid-batch.
@Suite struct VisibleProjectionTests {
    private func flow(
        _ n: Int, host: String = "a.test", status: Int? = 200, app: String? = nil, id: UUID? = nil
    ) -> Flow {
        var flow = Flow(
            id: id ?? UUID(),
            request: CapturedRequest(method: "GET", url: "https://\(host)/v1/\(n)", headers: []),
            startedAt: Date(timeIntervalSince1970: TimeInterval(n)),
            outcome: status.map {
                .completed(CapturedResponse(statusCode: $0, headers: []), at: Date(timeIntervalSince1970: TimeInterval(n) + 1))
            } ?? .pending
        )
        if let app { flow.sourceApp = SourceApp(name: app, bundleID: app, pid: 1) }
        return flow
    }

    private func failed(_ flow: Flow) -> Flow {
        var copy = flow
        copy.outcome = .failed(FlowError("boom"), at: Date(), partialResponse: nil)
        return copy
    }

    /// What the projection *should* be: the definition, recomputed from scratch.
    private func rebuilt(_ state: AppFeature.State) -> [Flow.ID] {
        var fresh = state
        fresh.refreshVisibleFlows()
        return fresh.displayFlows.map(\.id)
    }

    private func check(
        _ state: AppFeature.State, _ label: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            state.displayFlows.map(\.id) == rebuilt(state),
            "\(label): the incremental projection disagrees with a full rebuild",
            sourceLocation: sourceLocation
        )
    }

    // MARK: Each transition, against the definition

    @Test func aPlainAppendUnderAHostCategory() {
        var state = AppFeature.State()
        let seed = (0 ..< 30).map { flow($0, host: $0.isMultiple(of: 2) ? "a.test" : "b.test") }
        state.recordFlows(seed)
        state.selectedCategory = .host("a.test")
        state.recordFlows((30 ..< 40).map { flow($0, host: $0.isMultiple(of: 2) ? "a.test" : "b.test") })
        check(state, "append under a host category")
        #expect(!state.displayFlows.isEmpty)
    }

    @Test func anExchangeCompletingIsUpdatedInPlace() {
        var state = AppFeature.State()
        let pending = (0 ..< 10).map { flow($0, status: nil) }
        state.recordFlows(pending)
        state.selectedCategory = .host("a.test")
        // The middle one answers, several batches later.
        state.recordFlows((10 ..< 15).map { flow($0) })
        var completed = pending[4]
        completed.outcome = .completed(CapturedResponse(statusCode: 503, headers: []), at: Date())
        state.recordFlows([completed])
        check(state, "an in-flight exchange completing")
        #expect(state.displayFlows.first(where: { $0.id == pending[4].id })?.statusCode == 503,
                "the updated value reaches the list, not just its position")
    }

    /// The case the fold must decline: a row that was not shown becomes shown, and it
    /// belongs where the capture has it, not at the end.
    @Test func anExchangeFailingUnderTheErrorsCategory() {
        var state = AppFeature.State()
        let seed = (0 ..< 20).map { flow($0, status: nil) }
        state.recordFlows(seed)
        state.selectedCategory = .errors
        #expect(state.displayFlows.isEmpty, "nothing pending is an error")

        state.recordFlows([failed(seed[3])])
        check(state, "an early exchange failing")
        state.recordFlows((20 ..< 25).map { flow($0, status: 500) })
        check(state, "later errors after an early one")
        state.recordFlows([failed(seed[1])])
        check(state, "an even earlier exchange failing after them")
        #expect(state.displayFlows.count == 7)
        #expect(state.displayFlows.map(\.id).prefix(2) == [seed[1].id, seed[3].id],
                "errors are listed in capture order, not in the order they failed")
    }

    @Test func attributionBackfilledUnderAnAppCategory() {
        var state = AppFeature.State()
        let seed = (0 ..< 20).map { flow($0, app: $0 < 10 ? "com.known" : nil) }
        state.recordFlows(seed)
        state.selectedCategory = .app("com.known")
        #expect(state.displayFlows.count == 10)

        // Newer matching traffic first, so "at its own place" and "at the end" are
        // distinguishable answers.
        let newer = (20 ..< 25).map { flow($0, app: "com.known") }
        state.recordFlows(newer)
        #expect(state.displayFlows.count == 15)

        var attributed = seed[15]
        attributed.sourceApp = SourceApp(name: "com.known", bundleID: "com.known", pid: 1)
        state.recordFlows([attributed])
        check(state, "attribution arriving for an older flow")
        #expect(state.displayFlows.count == 16)
        #expect(state.displayFlows.last?.id == newer.last?.id,
                "a backfilled flow belongs at its own place in the capture, not at the end")
    }

    /// The batch's own order and the capture's order differ whenever a slow exchange
    /// completes after a faster one started. Appending "as seen" would invert them.
    @Test func aSlowExchangeCompletingAfterAFasterOneStarted() {
        var state = AppFeature.State()
        state.recordFlows([flow(0)])
        state.selectedCategory = .host("a.test")

        let slow = flow(1, status: nil)
        let fast = flow(2)
        // One batch: the slow request starts, the fast one starts and answers, the slow
        // one answers. Capture order is slow-then-fast; emission order is not.
        state.recordFlows([slow, fast, {
            var done = slow
            done.outcome = .completed(CapturedResponse(statusCode: 200, headers: []), at: Date())
            return done
        }()])
        check(state, "interleaved starts and completions in one batch")
        #expect(state.displayFlows.map(\.id).suffix(2) == [slow.id, fast.id],
                "capture order, not emission order")
    }

    @Test func aNeedleNarrowsAndKeepsNarrowing() {
        var state = AppFeature.State()
        state.recordFlows((0 ..< 50).map { flow($0, host: "a.test") })
        state.search.isPresented = true
        state.search.text = "/v1/1"
        let before = state.displayFlows.count
        #expect(before > 0)
        state.recordFlows((100 ..< 130).map { flow($0, host: "a.test") })
        check(state, "a batch arriving with a needle active")
        #expect(state.displayFlows.count > before)
    }

    @Test func aPanelCategoryStaysEmpty() {
        var state = AppFeature.State()
        state.recordFlows((0 ..< 10).map { flow($0) })
        state.selectedCategory = .rules
        state.recordFlows((10 ..< 20).map { flow($0) })
        #expect(state.displayFlows.isEmpty)
        check(state, "a panel category")
    }

    @Test func switchingCategoryRebuilds() {
        var state = AppFeature.State()
        state.recordFlows((0 ..< 40).map { flow($0, host: $0 < 20 ? "a.test" : "b.test") })
        state.selectedCategory = .host("a.test")
        #expect(state.displayFlows.count == 20)
        state.selectedCategory = .host("b.test")
        #expect(state.displayFlows.count == 20)
        check(state, "after a category switch")
        state.selectedCategory = .all
        #expect(state.displayFlows.count == 40)
    }

    @Test func clearingResetsTheProjection() {
        var state = AppFeature.State()
        state.recordFlows((0 ..< 20).map { flow($0) })
        state.selectedCategory = .host("a.test")
        state.forgetCapturedFlows()
        #expect(state.displayFlows.isEmpty)
        state.recordFlows((20 ..< 30).map { flow($0) })
        check(state, "after a clear")
        #expect(state.displayFlows.count == 10)
    }

    /// A trim rewrites the head, so the fold has to stand aside for it.
    @Test func theDisplayCapTrimRebuilds() {
        var state = AppFeature.State()
        let cap = AppFeature.State.displayCap
        state.recordFlows((0 ..< cap).map { flow($0, host: $0.isMultiple(of: 2) ? "a.test" : "b.test") })
        state.selectedCategory = .host("a.test")
        let before = state.displayFlows.count
        state.recordFlows((cap ..< cap + 50).map { flow($0, host: "a.test") })
        check(state, "a batch that trips the display cap")
        #expect(state.displayFlows.count != before)
        #expect(state.flows.count <= cap, "the window never exceeds its cap")
    }

    // MARK: The cap's trim hysteresis

    @Test func theTrimCutsBelowTheCapAndSaysSo() {
        var state = AppFeature.State()
        let cap = AppFeature.State.displayCap
        state.recordFlows((0 ..< cap).map { flow($0) })
        #expect(state.flows.count == cap)
        #expect(state.droppedFlowCount == 0, "at the cap exactly, nothing has been dropped")

        state.recordFlows([flow(cap)])
        #expect(state.flows.count <= cap, "never above the cap: a row the store cannot resolve is worse")
        #expect(
            state.flows.count == cap - AppFeature.State.trimSlack,
            "one trim cuts to a slack below the cap, so the next few hundred batches cost nothing"
        )
        #expect(
            state.droppedFlowCount == AppFeature.State.trimSlack + 1,
            "and it reports every row it dropped"
        )

        // The point of the slack: the batches that follow do not trim at all.
        let after = state.droppedFlowCount
        state.recordFlows((cap + 1 ..< cap + 31).map { flow($0) })
        #expect(state.droppedFlowCount == after, "no trim while there is headroom")
    }

    @Test func aTrimmedSelectionIsCleared() {
        var state = AppFeature.State()
        let cap = AppFeature.State.displayCap
        let first = flow(0)
        state.recordFlow(first)
        state.recordFlows((1 ..< cap).map { flow($0) })
        state.selectedFlowID = first.id
        state.recordFlows([flow(cap)])
        #expect(state.flows[id: first.id] == nil)
        #expect(state.selectedFlowID == nil, "a dropped selection must not dangle")
    }
}
