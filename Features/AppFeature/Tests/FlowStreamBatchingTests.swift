import ComposableArchitecture
import Foundation
import Synchronization
import LoomSharedModels
import Testing

@testable import AppFeature

/// The flow stream emits as fast as traffic flows: 2-3 times per exchange, more for
/// a streaming response, once per WebSocket frame. Each emission used to be its own
/// TCA action — a full reducer run plus a SwiftUI invalidation of the table and
/// sidebar, hundreds of times a second under load. They are now coalesced into one
/// action per window.
///
/// The property that matters beyond throughput: **nothing may be dropped or
/// stranded**. A naive "flush when the batch is big enough" leaves the tail of a
/// burst unsent until the next request arrives — which reads to the user as a
/// request that never happened.
@MainActor
@Suite struct FlowStreamBatchingTests {
    private func flow(_ n: Int) -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "https://api.test/\(n)", headers: []),
            startedAt: Date(timeIntervalSince1970: TimeInterval(n)),
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date(timeIntervalSince1970: TimeInterval(n) + 1))
        )
    }

    /// Collect the actions `streamFlows` sends for a finite stream.
    private func batches(from flows: [Flow]) async -> [[Flow]] {
        let collected = Collected()
        await CaptureFeature.streamFlows(
            into: Send { action in
                if case let .flowsReceived(batch) = action { collected.append(batch) }
            },
            flowStream: {
                AsyncStream { continuation in
                    for flow in flows { continuation.yield(flow) }
                    continuation.finish()
                }
            },
            clock: ImmediateClock()
        )
        return collected.batches
    }

    @Test func everyFlowArrives_exactlyOnce_inOrder() async {
        let flows = (0 ..< 25).map(flow)
        let batches = await batches(from: flows)
        let delivered = batches.flatMap { $0 }
        #expect(delivered.map(\.id) == flows.map(\.id), "no drops, no duplicates, order preserved")
    }

    @Test func manyEmissions_collapseIntoFewerActions() async {
        let flows = (0 ..< 200).map(flow)
        let batches = await batches(from: flows)
        #expect(batches.count < flows.count, "the point of batching")
        #expect(batches.flatMap { $0 }.count == 200)
    }

    /// The tail of a burst must not be stranded when the stream goes quiet — the
    /// failure mode where a request appears to have never happened.
    /// The drop this guards against, forced deterministically: with a clock that is
    /// never advanced, the window never elapses, so the buffered flows can only leave
    /// via the end-of-stream flush. If that flush happens on a task the group has
    /// already cancelled, `Send` discards it silently (`guard !Task.isCancelled`) and
    /// the whole batch is gone.
    @Test func theBufferedTailSurvivesWhenTheWindowNeverElapses() async {
        let collected = Collected()
        let flows = (0 ..< 5).map(flow)
        await CaptureFeature.streamFlows(
            into: Send { action in
                if case let .flowsReceived(batch) = action { collected.append(batch) }
            },
            flowStream: {
                AsyncStream { continuation in
                    for flow in flows { continuation.yield(flow) }
                    continuation.finish()
                }
            },
            clock: TestClock()
        )
        #expect(collected.batches.flatMap { $0 }.map(\.id) == flows.map(\.id))
    }

    @Test func trailingFlows_areFlushedWhenTheStreamEnds() async {
        let single = flow(1)
        let batches = await batches(from: [single])
        #expect(batches.flatMap { $0 }.map(\.id) == [single.id])
    }

    @Test func emptyStream_sendsNothing() async {
        #expect(await batches(from: []).isEmpty, "no empty batches")
    }

    /// A batch must fold into state exactly as the same flows would one at a time.
    @Test func batchedAction_matchesOneAtATime() async {
        let flows = (0 ..< 5).map(flow)
        var oneAtATime = CaptureFeature.State()
        for flow in flows { oneAtATime.recordFlow(flow) }

        // A capture batch also schedules the coalesced re-read of the engine's
        // counters. The clock keeps it from firing inside the assertion, and
        // `exhaustivity = .off` lets the test end with it still parked — what is under
        // test here is the fold, not the refresh.
        let store = TestStore(initialState: CaptureFeature.State()) { CaptureFeature() } withDependencies: {
            $0.continuousClock = TestClock()
        }
        store.exhaustivity = .off
        await store.send(.flowsReceived(flows)) { state in
            for flow in flows { state.recordFlow(flow) }
        }
        #expect(store.state.flows.value == oneAtATime.flows.value)
        // The window's own size, not `status.capturedCount`: that field is the engine's
        // ring count again (see `engineStatusRefreshed`), and this test is about the fold.
        #expect(store.state.windowCount == oneAtATime.windowCount)
    }

    /// A batch containing the open selection still refreshes the inspector's
    /// hydrated copy, as the per-flow path did.
    @Test func batchRefreshesTheOpenSelection() async {
        let selected = flow(7)
        var initial = CaptureFeature.State(flows: [selected])
        initial.selectedFlowID = selected.id
        let store = TestStore(initialState: initial) { CaptureFeature() } withDependencies: {
            $0.continuousClock = TestClock()
        }
        store.exhaustivity = .off

        var completed = selected
        completed.outcome = .completed(
            CapturedResponse(statusCode: 201, headers: [], body: Data("hi".utf8)),
            at: Date(timeIntervalSince1970: 9)
        )
        await store.send(.flowsReceived([completed])) { state in
            state.recordFlow(completed)
            state.selectedFlowDetail = completed
        }
        #expect(store.state.selectedFlowDetail?.response?.body == Data("hi".utf8),
                "the inspector keeps the body-carrying copy")
    }
}

/// Minimal thread-safe sink — the `Send` closure is called from a task group.
private final class Collected: Sendable {
    private let storage = Mutex<[[Flow]]>([])

    func append(_ batch: [Flow]) {
        storage.withLock { $0.append(batch) }
    }

    var batches: [[Flow]] {
        storage.withLock { $0 }
    }
}
