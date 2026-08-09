import ComposableArchitecture
import Foundation
import LoomSharedModels
import Testing

@testable import AppFeature

/// The sidebar's host / app / device / error aggregates and the projections built on
/// them (ordering, pinning, per-group representatives).
///
/// **The counts are the engine's now**, over everything retained rather than over what
/// this window holds — so these seed `state.aggregates` the way the engine's refresh
/// does, instead of expecting `recordFlow` to fold them. That is the behaviour change:
/// folding locally made every badge a count of the newest 2000 exchanges against a
/// store keeping 20 000, and a host whose flows had aged out of the window vanished
/// from the sidebar while its rows sat on disk. What these still pin is everything
/// downstream of the numbers, plus the folding rules themselves (`FlowAggregates`
/// lives in SharedModels and is exercised directly).
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

    /// Record flows into the window *and* set the counts the engine would report for
    /// them — the two halves that used to be one call.
    private func state(_ flows: [Flow]) -> AppFeature.State {
        var state = AppFeature.State()
        var aggregates = FlowAggregates()
        for flow in flows {
            state.recordFlow(flow)
            aggregates.contribute(flow)
        }
        state.aggregates = aggregates
        return state
    }

    @Test func counts_matchTheFlowsRecorded() {
        let state = state([
            flow(url: "https://a.test/1"),
            flow(url: "https://a.test/2"),
            flow(url: "https://b.test/1", status: 500),
        ])
        #expect(state.hosts.first(where: { $0.host == "a.test" })?.count == 2)
        #expect(state.hosts.first(where: { $0.host == "b.test" })?.count == 1)
        #expect(state.errorCount == 1)
        #expect(state.allCount == 3)
    }

    /// The folding rules themselves, now exercised on `FlowAggregates` directly — the
    /// engine is what folds, and it folds with this type.
    ///
    /// A flow upserts several times per exchange (pending → completed, plus streaming
    /// updates), and each update must replace its predecessor's contribution rather
    /// than add to it.
    @Test func upsertingTheSameFlow_doesNotDoubleCount() {
        var aggregates = FlowAggregates()
        let id = UUID()
        let pending = flow(id: id, url: "https://a.test/1", status: nil)
        let completed = flow(id: id, url: "https://a.test/1", status: 200)
        aggregates.contribute(pending)
        aggregates.retract(pending)
        aggregates.contribute(completed)

        #expect(aggregates.hostCounts["a.test"] == 1)
        #expect(aggregates.errorCount == 0)
    }

    /// pending → 500 must *become* an error, and 500 → (re-sent as) 200 must stop
    /// being one.
    @Test func errorCount_followsOutcomeTransitions() {
        var aggregates = FlowAggregates()
        let id = UUID()
        var current = flow(id: id, status: nil)
        aggregates.contribute(current)
        #expect(aggregates.errorCount == 0, "pending is not an error")

        func replace(with next: Flow) {
            aggregates.retract(current)
            aggregates.contribute(next)
            current = next
        }
        replace(with: flow(id: id, status: 503))
        #expect(aggregates.errorCount == 1)
        replace(with: flow(id: id, status: 200))
        #expect(aggregates.errorCount == 0, "the previous version's contribution was retracted")
        replace(with: flow(id: id, status: nil, error: "timeout"))
        #expect(aggregates.errorCount == 1, "a transport failure counts too")
    }

    /// **This asserted the opposite before, and the reversal is the fix.**
    ///
    /// It read "evicted flows must be subtracted, not left counted" — true of a counter
    /// over the window, and wrong for the thing the sidebar claims to show. A flow
    /// rolling out of the window has not left the capture: it is on disk, it is
    /// findable by search, `get_recent_flows` returns it. Subtracting it made the badge
    /// count the newest 2000 exchanges, so a busy host read as a quiet one and a host
    /// with no *recent* traffic disappeared from the sidebar entirely.
    ///
    /// The engine's counts are over what is retained, so the window rolling changes
    /// nothing about them.
    @Test func eviction_fromTheWindow_doesNotChangeTheCounts() {
        var state = AppFeature.State()
        var aggregates = FlowAggregates()
        for index in 0 ..< AppFeature.State.displayCap {
            let flow = flow(url: "https://old.test/\(index)")
            state.recordFlow(flow)
            aggregates.contribute(flow)
        }
        for index in 0 ..< 10 {
            let flow = flow(url: "https://new.test/\(index)")
            state.recordFlow(flow)
            aggregates.contribute(flow)
        }
        state.aggregates = aggregates

        #expect(state.allCount == AppFeature.State.displayCap, "the window cap holds")
        #expect(state.droppedFlowCount == 10, "and it dropped rows to hold it")
        #expect(state.hosts.first(where: { $0.host == "old.test" })?.count == AppFeature.State.displayCap,
                "every one of them is still retained, so still counted")
        #expect(state.hosts.first(where: { $0.host == "new.test" })?.count == 10)
    }

    /// A host/app/device whose last flow is gone must leave the sidebar, not sit
    /// there at zero.
    @Test func emptiedKeys_disappear() {
        let app = SourceApp(name: "Solo", bundleID: "com.solo", pid: 1)
        let device = SourceDevice(ip: "192.168.1.5", kind: .lan, platform: "iOS", client: nil)
        var state = state([flow(url: "https://solo.test/1", app: app, device: device)])
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
        let bare = SourceDevice(ip: "192.168.1.9", kind: .lan, platform: nil, client: nil)
        let typed = SourceDevice(ip: "192.168.1.9", kind: .lan, platform: "iOS", client: "Safari")
        let state = state([flow(device: bare), flow(device: typed)])
        let entry = state.devices.first
        #expect(entry?.count == 2)
        #expect(entry?.device.platform == "iOS", "a later flow's richer typing is kept")
        #expect(entry?.device.client == "Safari")
    }

    @Test func devices_lanFloatsAboveLocal() {
        let state = state([
            flow(device: SourceDevice(ip: "127.0.0.1", kind: .local, platform: nil, client: nil)),
            flow(device: SourceDevice(ip: "127.0.0.1", kind: .local, platform: nil, client: nil)),
            flow(device: SourceDevice(ip: "192.168.1.9", kind: .lan, platform: nil, client: nil)),
        ])
        #expect(state.devices.first?.device.kind == .lan, "the phone you just connected leads")
    }

    @Test func hosts_pinnedFloatToTop() {
        var state = state(["c.test", "a.test", "b.test"].map { flow(url: "https://\($0)/1") })
        state.pinnedHosts = ["c.test"]
        #expect(state.hosts.map(\.host) == ["c.test", "a.test", "b.test"])
    }

    @Test func apps_pinnedFloatToTop_thenMostActive() {
        let pinned = SourceApp(name: "Pinned", bundleID: "com.pinned", pid: 1)
        let busy = SourceApp(name: "Busy", bundleID: "com.busy", pid: 2)
        var state = state([flow(app: pinned)] + (0 ..< 5).map { _ in flow(app: busy) })
        state.pinnedApps = ["com.pinned"]
        #expect(state.apps.map(\.app.groupingKey) == ["com.pinned", "com.busy"])
    }

    /// The empty-state branch and the table must never disagree about emptiness, for
    /// any category, or the window shows an empty state over a non-empty table.
    ///
    /// Since the counts moved to the engine this can no longer be answered from them at
    /// all — they cover 20 000 retained rows while the window holds 2 000, so a host
    /// whose flows have rolled out has a non-zero count and no rows. Both sides now read
    /// the cached projection, and `selectedCategory` is set through the funnel so the
    /// cache is what a real category tap would leave behind.
    @Test func displayFlowsAreEmpty_agreesWithDisplayFlows() {
        let device = SourceDevice(ip: "192.168.1.9", kind: .lan, platform: nil, client: nil)
        let app = SourceApp(name: "App", bundleID: "com.app", pid: 1)
        var state = state([
            flow(url: "https://a.test/1", status: 500),
            flow(url: "https://b.test/1", app: app, device: device),
        ])

        let categories: [FlowCategory?] = [
            nil, .all, .errors, .host("a.test"), .host("missing.test"),
            .app("com.app"), .app("com.other"), .device("192.168.1.9"), .device("10.0.0.1"),
            .rules, .audit, .breakpoints,
        ]
        for category in categories {
            state.selectedCategory = category
            state.refreshVisibleFlows()
            #expect(
                state.displayFlowsAreEmpty == state.displayFlows.isEmpty,
                "disagree under \(String(describing: category))"
            )
        }

        state.forgetCapturedFlows()
        state.selectedCategory = .all
        state.refreshVisibleFlows()
        #expect(state.displayFlowsAreEmpty)
    }

    /// A whole stream batch lands through `recordFlows`, which trims the cap once
    /// at the end instead of per flow — the state it leaves must be exactly what
    /// per-flow recording produced, including the drop count, the aggregates, and
    /// a selection that fell off the front.
    @Test func batchRecording_matchesPerFlowRecording_atTheCap() {
        let seed = (0 ..< AppFeature.State.displayCap).map { flow(url: "https://old.test/\($0)") }
        let batch = (0 ..< 10).map { flow(url: "https://new.test/\($0)") }

        var perFlow = AppFeature.State(flows: seed)
        var batched = AppFeature.State(flows: seed)
        let evicted = perFlow.flows.first!.id
        perFlow.selectedFlowID = evicted
        batched.selectedFlowID = evicted

        for flow in batch { perFlow.recordFlow(flow) }
        batched.recordFlows(batch)

        #expect(batched.flows == perFlow.flows)
        #expect(batched.allCount == AppFeature.State.displayCap, "the cap holds")
        #expect(batched.droppedFlowCount == perFlow.droppedFlowCount)
        #expect(batched.hostByRow == perFlow.hostByRow, "the per-row index matches too")
        #expect(batched.selectedFlowID == nil, "a selection dropped by the trim is cleared")
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
        #expect(seeded.hostByRow == incremental.hostByRow)
        #expect(seeded.displayFlows.map(\.id) == incremental.displayFlows.map(\.id),
                "including the cached projection, which a stale cache would fail")
    }
}

/// `AppFeature.State.hostByRow` — the per-row host index. It is keyed by *flow*
/// rather than by host, so it has a way to go wrong the counters don't: an entry that
/// outlives its row makes a row match a category it is no longer in, and one dropped
/// too early makes it vanish from a filtered list while the sidebar still counts it.
@Suite struct FlowHostIndexTests {
    private func flow(_ url: String) -> Flow {
        Flow(
            request: CapturedRequest(method: "GET", url: url, headers: []),
            startedAt: Date()
        )
    }

    /// The per-row host map moved to `AppFeature.State` when the counters moved to the
    /// engine. It is the one projection keyed by *flow* rather than by host, so a copy
    /// covering everything retained (20 000 rows) would reintroduce exactly the
    /// per-flow memory the windowed list exists to remove — a per-row map belongs to
    /// whoever holds the rows.
    @Test func theWindowIndexesTheHostOfEveryRowItHolds() {
        var state = AppFeature.State()
        let a = flow("https://api.example.test/v1")
        state.recordFlow(a)
        #expect(state.hostByRow[a.id] == "api.example.test")
    }

    /// The eviction path: a flow dropped past the display cap must leave no index
    /// entry behind, or the map grows for the life of the session.
    @Test func aFlowEvictedByTheDisplayCapLeavesNoEntry() {
        var state = AppFeature.State()
        let first = flow("https://first.example.test/v1")
        state.recordFlow(first)
        for i in 0 ..< AppFeature.State.displayCap {
            state.recordFlow(flow("https://bulk.example.test/\(i)"))
        }
        #expect(state.flows[id: first.id] == nil)
        #expect(state.hostByRow[first.id] == nil)
        #expect(state.hostByRow.count == state.flows.count)
    }

    /// An upsert (pending → completed) replaces rather than duplicates, and the index
    /// must not be left pointing at the old copy's host if the URL changed.
    @Test func replacingAFlowRepointsTheIndex() {
        var state = AppFeature.State()
        var moved = flow("https://before.example.test/v1")
        state.recordFlow(moved)
        moved.request.url = "https://after.example.test/v1"
        state.recordFlow(moved)
        #expect(state.hostByRow[moved.id] == "after.example.test")
    }

    /// Clearing the capture drops the row index with the rows.
    @Test func clearingDropsTheIndex() {
        var state = AppFeature.State()
        state.recordFlow(flow("https://api.example.test/v1"))
        state.forgetCapturedFlows()
        #expect(state.hostByRow.isEmpty)
    }
}
