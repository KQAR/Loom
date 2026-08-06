import Testing
import Foundation
import Synchronization
import LoomSharedModels
@testable import LoomProxyCore

/// The push observer + store-less mode (issue #42): an embedder that owns its
/// storage gets every flow update pushed, and can run the ring at `capacity: 0`
/// so Loom retains nothing.
@Suite struct FlowObserverTests {
    private func flow(_ url: String = "https://api.example.test/x") -> Flow {
        Flow(id: UUID(),
             request: CapturedRequest(method: "GET", url: url, headers: []),
             startedAt: Date(),
             outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date()))
    }

    @Test func observer_receivesEveryUpsert() async {
        let spy = FlowSpy()
        let store = FlowStore(persistence: nil, observer: spy)
        let f = flow()
        await store.upsert(Flow(id: f.id, request: f.request, startedAt: f.startedAt)) // start
        await store.upsert(f) // completion

        #expect(spy.count == 2)
        #expect(spy.ids == [f.id, f.id])
    }

    @Test func storeLess_retainsNothing_butStillPushes() async {
        let spy = FlowSpy()
        let store = FlowStore(capacity: 0, persistence: nil, observer: spy)
        let f = flow()
        await store.upsert(f)

        // Nothing retained…
        #expect(await store.count == 0)
        #expect(await store.recent(limit: 10).isEmpty)
        #expect(await store.flow(id: f.id) == nil)
        // …but the update was still delivered.
        #expect(spy.count == 1)
        #expect(spy.ids == [f.id])
    }
}

private final class FlowSpy: FlowObserving, Sendable {
    private let _ids = Mutex<[UUID]>([])
    var ids: [UUID] { _ids.withLock { $0 } }
    var count: Int { _ids.withLock { $0.count } }

    func flowDidUpdate(_ flow: Flow) {
        _ids.withLock { $0.append(flow.id) }
    }
}
