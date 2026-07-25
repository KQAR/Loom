import Testing
import Foundation
@testable import LoomProxyCore
import LoomSharedModels

/// `clear_flows` over MCP wipes the store, but the main window holds its own copy
/// of the flow list and only cleared it from its own button. Without a broadcast
/// the human would keep supervising flows the engine no longer has — a stale view
/// of what the agent did. The store therefore announces every clear.
@Suite struct FlowStoreClearSignalTests {
    private func flow(_ url: String) -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: url, headers: []),
            startedAt: Date(),
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date())
        )
    }

    @Test func clear_notifiesSubscribers() async throws {
        let store = FlowStore()
        await store.upsert(flow("https://a/1"))
        let stream = await store.clearedStream()

        let observed = Task { () -> Bool in
            for await _ in stream { return true }
            return false
        }
        await store.clear()

        #expect(await observed.value, "a clear must reach subscribers")
        #expect(await store.count == 0)
    }

    @Test func engineExposesTheClearSignal() async throws {
        let engine = ProxyEngine(persistFlows: false)
        let stream = await engine.flowsClearedStream()
        let observed = Task { () -> Bool in
            for await _ in stream { return true }
            return false
        }
        await engine.clearFlows()
        #expect(await observed.value)
    }

    /// Several surfaces can listen (window + a future panel); all of them get it.
    @Test func clear_fansOutToEverySubscriber() async throws {
        let store = FlowStore()
        let first = await store.clearedStream()
        let second = await store.clearedStream()
        let a = Task { for await _ in first { return true }; return false }
        let b = Task { for await _ in second { return true }; return false }
        await store.clear()
        #expect(await a.value)
        #expect(await b.value)
    }
}
