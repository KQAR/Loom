import ComposableArchitecture
import Foundation
import LoomSharedModels
import Testing
@testable import AppFeature

/// `reveal_flow`: reset exactly the filters hiding a flow, then select it. The human's
/// other filters are theirs and stay put; the report the agent gets and the reset the
/// reducer does come from one function (`revealPlan`), so they can't disagree.
@MainActor
@Suite struct RevealFlowTests {
    private let api = Fixtures.flow(url: "https://api.example.com/orders")
    private let cdn = Fixtures.flow(url: "https://cdn.example.net/app.js")

    @Test func aVisibleFlowNeedsNothingReset() {
        let state = CaptureFeature.State(flows: [api, cdn])
        #expect(state.revealPlan(for: api.id) == [])
    }

    @Test func aFlowOutsideTheWindowHasNoPlan() {
        #expect(CaptureFeature.State(flows: [api]).revealPlan(for: UUID()) == nil)
    }

    @Test func onlyTheFiltersThatExcludeItAreReset() {
        var state = CaptureFeature.State(flows: [api, cdn])
        state.selection = [.host("cdn.example.net")]
        state.search.isPresented = true
        state.search.text = "orders" // matches api, so the find bar stays
        #expect(state.revealPlan(for: api.id) == [.sidebarSelection])

        state.search.text = "app.js"
        #expect(state.revealPlan(for: api.id) == [.sidebarSelection, .findBar])
    }

    @Test func aPanelInPlaceOfTheTableIsReset() {
        var state = CaptureFeature.State(flows: [api])
        state.selection = [.rules]
        #expect(state.revealPlan(for: api.id) == [.sidebarSelection])
    }

    @Test func revealResetsThenSelects() async {
        var initial = CaptureFeature.State(flows: [api, cdn])
        initial.selection = [.host("cdn.example.net")]
        initial.search.isPresented = true
        initial.search.text = "app.js"
        let store = TestStore(initialState: initial) { CaptureFeature() } withDependencies: {
            $0.proxyClient.flow = { [api] _ in api }
        }
        store.exhaustivity = .off
        await store.send(.revealFlow(api.id))
        await store.receive(\.flowSelected)
        await store.skipReceivedActions()
        #expect(store.state.selection == [.all])
        #expect(!store.state.search.isPresented)
        #expect(store.state.selectedFlowID == api.id)
        #expect(store.state.displayFlows.value.contains { $0.id == api.id })
    }
}
