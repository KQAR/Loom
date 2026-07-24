import ComposableArchitecture
import Foundation
import SharedModels
import Testing

@testable import AppFeature

/// The `AppFeature.State` computed projections that drive the sidebar + table.
/// Pure functions of `flows` + selection — no store needed.
@Suite struct StateProjectionTests {
    private func state(_ flows: [Flow], category: FlowCategory? = .all) -> AppFeature.State {
        var s = AppFeature.State()
        s.flows = IdentifiedArray(uniqueElements: flows)
        s.selectedCategory = category
        return s
    }

    @Test func displayFlows_all_keepsInsertionOrder() {
        let a = Fixtures.flow(url: "https://a.com/1")
        let b = Fixtures.flow(url: "https://b.com/2")
        let s = state([a, b])
        #expect(s.displayFlows.map(\.id) == [a.id, b.id])
    }

    @Test func displayFlows_errors_matchesStatusOrError() {
        let ok = Fixtures.flow(status: 200)
        let http500 = Fixtures.flow(status: 500)
        let failed = Fixtures.flow(status: nil, responseBody: nil, error: "timeout")
        let s = state([ok, http500, failed], category: .errors)
        #expect(Set(s.displayFlows.map(\.id)) == [http500.id, failed.id])
        #expect(s.errorCount == 2)
    }

    @Test func displayFlows_replayed_onlyReplays() {
        let live = Fixtures.flow()
        let replay = Fixtures.flow(replayedFrom: live.id)
        let s = state([live, replay], category: .replayed)
        #expect(s.displayFlows.map(\.id) == [replay.id])
        #expect(s.replayedCount == 1)
    }

    @Test func displayFlows_rulesCategory_isEmpty() {
        // The rules panel replaces the table, so the flow list must be empty.
        let s = state([Fixtures.flow()], category: .rules)
        #expect(s.displayFlows.isEmpty)
    }

    @Test func displayFlows_host_filtersByHost() {
        let a = Fixtures.flow(url: "https://a.com/x")
        let b = Fixtures.flow(url: "https://b.com/y")
        let s = state([a, b], category: .host("b.com"))
        #expect(s.displayFlows.map(\.id) == [b.id])
    }

    @Test func hosts_pinnedFloatToTop_thenAlphabetical() {
        let flows = [
            Fixtures.flow(url: "https://charlie.com/1"),
            Fixtures.flow(url: "https://alpha.com/1"),
            Fixtures.flow(url: "https://bravo.com/1"),
        ]
        var s = state(flows)
        s.pinnedHosts = ["charlie.com"]
        #expect(s.hosts.map(\.host) == ["charlie.com", "alpha.com", "bravo.com"])
    }

    @Test func hosts_countsPerHost() {
        let flows = [
            Fixtures.flow(url: "https://a.com/1"),
            Fixtures.flow(url: "https://a.com/2"),
            Fixtures.flow(url: "https://b.com/1"),
        ]
        let s = state(flows)
        #expect(s.hosts.first(where: { $0.host == "a.com" })?.count == 2)
        #expect(s.hosts.first(where: { $0.host == "b.com" })?.count == 1)
    }

    @Test func apps_pinnedFloatToTop_thenMostActive() {
        func f(_ bundle: String) -> Flow {
            Fixtures.flow(sourceApp: SourceApp(name: bundle, bundleID: bundle, pid: 1))
        }
        // com.busy has 2, com.quiet + com.pinned have 1 each.
        var s = state([f("com.busy"), f("com.busy"), f("com.quiet"), f("com.pinned")])
        s.pinnedApps = ["com.pinned"]
        let keys = s.apps.map(\.app.groupingKey)
        #expect(keys.first == "com.pinned")       // pinned floats up despite lower count
        #expect(keys.dropFirst().first == "com.busy") // then most-active
    }

    @Test func selectedFlow_resolvesByID() {
        let flow = Fixtures.flow()
        var s = state([flow])
        s.selectedFlowID = flow.id
        #expect(s.selectedFlow?.id == flow.id)
        #expect(s.allCount == 1)
    }

    // MARK: Session display cap (② capacity visibility)

    @Test func recordFlow_underCap_dropsNothing() {
        var s = AppFeature.State()
        let flows = (0 ..< 5).map { _ in Fixtures.flow() }
        flows.forEach { s.recordFlow($0) }
        #expect(s.flows.count == 5)
        #expect(s.droppedFlowCount == 0)
    }

    @Test func recordFlow_overCap_dropsOldestAndCounts() {
        var s = AppFeature.State()
        let cap = AppFeature.State.displayCap
        let flows = (0 ..< (cap + 3)).map { _ in Fixtures.flow() }
        flows.forEach { s.recordFlow($0) }

        #expect(s.flows.count == cap, "held to the cap")
        #expect(s.droppedFlowCount == 3, "the 3 oldest were dropped")
        #expect(s.flows.last?.id == flows.last?.id, "newest is retained")
        #expect(s.flows[id: flows[0].id] == nil, "oldest is gone")
        #expect(s.flows.first?.id == flows[3].id, "oldest survivor is the 4th inserted")
    }

    @Test func recordFlow_upsertExistingID_doesNotCountAsNew() {
        var s = AppFeature.State()
        let flow = Fixtures.flow(status: nil, responseBody: nil) // in-flight
        s.recordFlow(flow)
        s.recordFlow(Fixtures.flow(id: flow.id, status: 200)) // completion re-arrives
        #expect(s.flows.count == 1)
        #expect(s.flows[id: flow.id]?.statusCode == 200)
        #expect(s.droppedFlowCount == 0)
    }

    @Test func recordFlow_droppingSelectedClearsSelection() {
        var s = AppFeature.State()
        let first = Fixtures.flow()
        s.recordFlow(first)
        s.selectedFlowID = first.id
        // Push exactly past the cap so `first` (the oldest) is evicted.
        (0 ..< AppFeature.State.displayCap).forEach { _ in s.recordFlow(Fixtures.flow()) }
        #expect(s.flows[id: first.id] == nil)
        #expect(s.selectedFlowID == nil, "a dropped selection must not dangle")
    }
}
