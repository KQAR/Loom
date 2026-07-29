import Testing
import Foundation
import NIOCore
import NIOEmbedded
@testable import LoomProxyCore
import LoomSharedModels

/// The sink owns an unstored `Task` that lives until its stream ends. Every exit
/// from a WebSocket relay must therefore end that stream — including the one where
/// the relay never starts, which is how it leaked: the only caller of `finish()` is
/// a tap handler's `channelInactive`, and on a pipeline-installation failure neither
/// tap is ever added, so that callback never comes.
@Suite("WebSocket capture sink", .timeLimit(.minutes(1)))
struct WebSocketCaptureSinkTests {
    private let loop = EmbeddedEventLoop()

    private func makeSink(store: FlowStore, id: UUID = UUID()) -> WebSocketCaptureSink {
        WebSocketCaptureSink(
            flowID: id,
            request: CapturedRequest(method: "GET", url: "wss://api.test/socket", headers: []),
            startedAt: Date(timeIntervalSince1970: 0),
            sourceApp: nil, sourceDevice: nil,
            eventLoop: loop, store: store
        )
    }

    /// The relay reached the client — the flow completes and is recorded.
    @Test func finish_publishesACompletedFlow() async throws {
        let store = FlowStore(capacity: 8, persistence: nil)
        let id = UUID()
        let sink = makeSink(store: store, id: id)

        sink.finish()

        try await untilStored(store, id: id)
        let flow = try #require(await store.flow(id: id))
        #expect(flow.completedAt != nil, "a finished socket is a completed flow")
    }

    /// The relay never started: no tap was installed, no byte crossed. Recording a
    /// completed WebSocket flow here would invent an exchange that never happened.
    @Test func abandon_publishesNothing() async throws {
        let store = FlowStore(capacity: 8, persistence: nil)
        let id = UUID()
        let sink = makeSink(store: store, id: id)

        sink.abandon()

        // Give the consumer task room to have upserted, if it were going to.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await store.flow(id: id) == nil, "an abandoned relay must leave no flow behind")
    }

    /// Both are idempotent, because a socket can go inactive on either side and the
    /// failure branch can race a teardown.
    @Test func finishAndAbandon_areIdempotentAndMutuallyExclusive() async throws {
        let store = FlowStore(capacity: 8, persistence: nil)
        let id = UUID()
        let sink = makeSink(store: store, id: id)

        sink.finish()
        sink.finish()
        sink.abandon() // must not undo or double-publish

        try await untilStored(store, id: id)
        #expect(await store.count == 1, "one flow, however many times we close it")
    }

    /// Poll rather than sleep a fixed time: the consumer is a detached task, so the
    /// upsert lands whenever it is scheduled.
    private func untilStored(_ store: FlowStore, id: UUID, within seconds: Double = 2) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await store.flow(id: id) != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the sink never published a flow")
    }
}
