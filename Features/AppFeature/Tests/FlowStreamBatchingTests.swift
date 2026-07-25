import ComposableArchitecture
import Foundation
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
        await AppFeature.streamFlows(
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
        var oneAtATime = AppFeature.State()
        for flow in flows { oneAtATime.recordFlow(flow) }

        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        await store.send(.flowsReceived(flows)) { state in
            for flow in flows { state.recordFlow(flow) }
        }
        #expect(store.state.flows == oneAtATime.flows)
        #expect(store.state.errorCount == oneAtATime.errorCount)
        #expect(store.state.status.capturedCount == oneAtATime.status.capturedCount)
    }

    /// A batch containing the open selection still refreshes the inspector's
    /// hydrated copy, as the per-flow path did.
    @Test func batchRefreshesTheOpenSelection() async {
        let selected = flow(7)
        var initial = AppFeature.State(flows: [selected])
        initial.selectedFlowID = selected.id
        let store = TestStore(initialState: initial) { AppFeature() }

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
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[Flow]] = []

    func append(_ batch: [Flow]) {
        lock.lock(); defer { lock.unlock() }
        storage.append(batch)
    }

    var batches: [[Flow]] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
