import ComposableArchitecture
import Foundation
import LoomSharedModels
import Testing

@testable import AppFeature

/// The sidebar's host / app / device / error aggregates used to be computed by
/// scanning every flow on each render — four O(n) passes, one of which parsed
/// every URL through `URLComponents`. They are now maintained incrementally, which
/// only works if every mutation path keeps them in step with `flows`. That's the
/// invariant these tests hold down: an upsert must not double-count, an eviction
/// must subtract, and an emptied key must disappear rather than linger at zero.
@Suite struct FlowAggregateTests {
    private func flow(
        id: UUID = UUID(),
        url: String = "https://api.example.com/v1",
        status: Int? = 200,
        error: String? = nil,
        app: SourceApp? = nil,
        device: SourceDevice? = nil,
        at seconds: TimeInterval = 1_000
    ) -> Flow {
        let outcome: FlowOutcome
        if let error {
            outcome = .failed(FlowError(error), at: Date(timeIntervalSince1970: seconds), partialResponse: nil)
        } else if let status {
            outcome = .completed(CapturedResponse(statusCode: status, headers: []), at: Date(timeIntervalSince1970: seconds))
        } else {
            outcome = .pending
        }
        return Flow(
            id: id,
            request: CapturedRequest(method: "GET", url: url, headers: []),
            startedAt: Date(timeIntervalSince1970: seconds),
            outcome: outcome, sourceApp: app, sourceDevice: device
        )
    }

    @Test func counts_matchTheFlowsRecorded() {
        var state = AppFeature.State()
        state.recordFlow(flow(url: "https://a.test/1"))
        state.recordFlow(flow(url: "https://a.test/2"))
        state.recordFlow(flow(url: "https://b.test/1", status: 500))

        #expect(state.hosts.first(where: { $0.host == "a.test" })?.count == 2)
        #expect(state.hosts.first(where: { $0.host == "b.test" })?.count == 1)
        #expect(state.errorCount == 1)
        #expect(state.allCount == 3)
    }

    /// The bug incremental counting invites: a flow upserts several times per
    /// exchange (pending → completed, plus streaming updates), and each update must
    /// replace its predecessor's contribution rather than add to it.
    @Test func upsertingTheSameFlow_doesNotDoubleCount() {
        var state = AppFeature.State()
        let id = UUID()
        state.recordFlow(flow(id: id, url: "https://a.test/1", status: nil)) // pending
        state.recordFlow(flow(id: id, url: "https://a.test/1", status: 200)) // completed
        state.recordFlow(flow(id: id, url: "https://a.test/1", status: 200)) // a stray re-emit

        #expect(state.allCount == 1)
        #expect(state.hosts.first(where: { $0.host == "a.test" })?.count == 1)
        #expect(state.errorCount == 0)
    }

    /// pending → 500 must *become* an error, and 500 → (re-sent as) 200 must stop
    /// being one.
    @Test func errorCount_followsOutcomeTransitions() {
        var state = AppFeature.State()
        let id = UUID()
        state.recordFlow(flow(id: id, status: nil))
        #expect(state.errorCount == 0, "pending is not an error")
        state.recordFlow(flow(id: id, status: 503))
        #expect(state.errorCount == 1)
        state.recordFlow(flow(id: id, status: 200))
        #expect(state.errorCount == 0, "the previous version's contribution was retracted")
        state.recordFlow(flow(id: id, status: nil, error: "timeout"))
        #expect(state.errorCount == 1, "a transport failure counts too")
    }

    @Test func eviction_subtractsFromTheAggregates() {
        var state = AppFeature.State()
        // Fill past the display cap with one host, then push it out with another.
        for index in 0 ..< AppFeature.State.displayCap {
            state.recordFlow(flow(url: "https://old.test/\(index)"))
        }
        #expect(state.hosts.first(where: { $0.host == "old.test" })?.count == AppFeature.State.displayCap)

        for index in 0 ..< 10 {
            state.recordFlow(flow(url: "https://new.test/\(index)"))
        }
        #expect(state.allCount == AppFeature.State.displayCap, "the cap holds")
        #expect(state.droppedFlowCount == 10)
        #expect(state.hosts.first(where: { $0.host == "old.test" })?.count == AppFeature.State.displayCap - 10,
                "evicted flows must be subtracted, not left counted")
        #expect(state.hosts.first(where: { $0.host == "new.test" })?.count == 10)
    }

    /// A host/app/device whose last flow is gone must leave the sidebar, not sit
    /// there at zero.
    @Test func emptiedKeys_disappear() {
        var state = AppFeature.State()
        let app = SourceApp(name: "Solo", bundleID: "com.solo", pid: 1)
        let device = SourceDevice(ip: "192.168.1.5", kind: .lan, platform: "iOS", client: nil)
        state.recordFlow(flow(url: "https://solo.test/1", app: app, device: device))
        #expect(state.hosts.count == 1)
        #expect(state.apps.count == 1)
        #expect(state.devices.count == 1)

        state.forgetCapturedFlows()
        #expect(state.hosts.isEmpty)
        #expect(state.apps.isEmpty)
        #expect(state.devices.isEmpty)
        #expect(state.errorCount == 0)
        #expect(state.allCount == 0)
    }

    @Test func devices_keepTheRichestTypingAcrossFlows() {
        var state = AppFeature.State()
        let bare = SourceDevice(ip: "192.168.1.9", kind: .lan, platform: nil, client: nil)
        let typed = SourceDevice(ip: "192.168.1.9", kind: .lan, platform: "iOS", client: "Safari")
        state.recordFlow(flow(device: bare))
        state.recordFlow(flow(device: typed))
        let entry = state.devices.first
        #expect(entry?.count == 2)
        #expect(entry?.device.platform == "iOS", "a later flow's richer typing is kept")
        #expect(entry?.device.client == "Safari")
    }

    @Test func devices_lanFloatsAboveLocal() {
        var state = AppFeature.State()
        state.recordFlow(flow(device: SourceDevice(ip: "127.0.0.1", kind: .local, platform: nil, client: nil)))
        state.recordFlow(flow(device: SourceDevice(ip: "127.0.0.1", kind: .local, platform: nil, client: nil)))
        state.recordFlow(flow(device: SourceDevice(ip: "192.168.1.9", kind: .lan, platform: nil, client: nil)))
        #expect(state.devices.first?.device.kind == .lan, "the phone you just connected leads")
    }

    @Test func hosts_pinnedFloatToTop() {
        var state = AppFeature.State()
        for host in ["c.test", "a.test", "b.test"] {
            state.recordFlow(flow(url: "https://\(host)/1"))
        }
        state.pinnedHosts = ["c.test"]
        #expect(state.hosts.map(\.host) == ["c.test", "a.test", "b.test"])
    }

    @Test func apps_pinnedFloatToTop_thenMostActive() {
        var state = AppFeature.State()
        let pinned = SourceApp(name: "Pinned", bundleID: "com.pinned", pid: 1)
        let busy = SourceApp(name: "Busy", bundleID: "com.busy", pid: 2)
        state.recordFlow(flow(app: pinned))
        for _ in 0 ..< 5 { state.recordFlow(flow(app: busy)) }
        state.pinnedApps = ["com.pinned"]
        #expect(state.apps.map(\.app.groupingKey) == ["com.pinned", "com.busy"])
    }

    /// The seeding initializer must produce exactly the state live capture would.
    @Test func seedingInitializer_matchesIncrementalRecording() {
        let flows = [
            flow(url: "https://a.test/1", status: 500),
            flow(url: "https://a.test/2"),
            flow(url: "https://b.test/1"),
        ]
        var incremental = AppFeature.State()
        for flow in flows { incremental.recordFlow(flow) }
        let seeded = AppFeature.State(flows: flows)

        #expect(seeded.flows == incremental.flows)
        #expect(seeded.errorCount == incremental.errorCount)
        #expect(seeded.hosts.map(\.host) == incremental.hosts.map(\.host))
        #expect(seeded.hosts.map(\.count) == incremental.hosts.map(\.count))
    }
}
