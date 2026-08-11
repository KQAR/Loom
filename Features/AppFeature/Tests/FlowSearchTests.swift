import ComposableArchitecture
import Foundation
import LoomSharedModels
import Testing

@testable import AppFeature

/// The main window's find bar (⌘F).
///
/// What these pin is the half that was missing rather than wrong: `FlowQuery` has
/// carried `urlContains` / `headerContains` / `bodyContains` since M6 and
/// `ProxyClient.recentFlowsMatching` was wired to it, but no view ever called it — so
/// an agent could search the capture and the human supervising it could not.
/// `ProxyClientParityTests` passes on a capability that is *wired*, which that one
/// was, so nothing failed.
@Suite struct FlowSearchTests {
    private func state(_ flows: [Flow], category: FlowCategory? = .all) -> CaptureFeature.State {
        var state = CaptureFeature.State(flows: flows)
        state.selectedCategory = category
        return state
    }

    // MARK: The needle, and how it composes with the sidebar

    @Test func urlScope_filtersLocally() {
        var state = state([
            Fixtures.flow(url: "https://a.com/orders/1"),
            Fixtures.flow(url: "https://a.com/health"),
        ])
        state.search.isPresented = true
        state.search.text = "orders"
        #expect(state.displayFlows.map(\.request.url) == ["https://a.com/orders/1"])
    }

    @Test func urlScope_isCaseInsensitive() {
        var state = state([Fixtures.flow(url: "https://a.com/Orders/1")])
        state.search.isPresented = true
        state.search.text = "ORDERS"
        #expect(state.displayFlows.count == 1)
    }

    /// The two filters are different questions and compose as AND: the category picks
    /// whose traffic, the needle picks which exchange.
    @Test func needleComposesWithTheSidebarCategory() {
        let match = Fixtures.flow(url: "https://b.com/orders/1")
        var state = state([
            Fixtures.flow(url: "https://a.com/orders/1"),
            match,
            Fixtures.flow(url: "https://b.com/health"),
        ], category: .host("b.com"))
        state.search.isPresented = true
        state.search.text = "orders"
        #expect(state.displayFlows.map(\.id) == [match.id])
    }

    /// Searching must not move the sidebar counts. A badge that tracked the needle
    /// could no longer answer the one question worth asking when a result is empty:
    /// too narrow a filter, or traffic that isn't there?
    @Test func searchingLeavesTheSidebarBadgesAlone() {
        var state = state([Fixtures.flow(status: 500), Fixtures.flow(status: 500)])
        let before = state.errorCount
        state.search.isPresented = true
        state.search.text = "nothing-matches-this"
        #expect(state.displayFlows.isEmpty)
        #expect(state.errorCount == before)
    }

    /// Whitespace is not a needle: trimming to empty would filter everything out and
    /// render as "no traffic".
    @Test func whitespaceIsNotASearch() {
        var state = state([Fixtures.flow(url: "https://a.com/x")])
        state.search.isPresented = true
        state.search.text = "   "
        #expect(!state.search.isActive)
        #expect(state.displayFlows.count == 1)
    }

    /// A hidden bar filters nothing, which is what makes "dismiss clears" a property
    /// of one place rather than of every call site.
    @Test func aHiddenBarFiltersNothing() {
        var state = state([Fixtures.flow(url: "https://a.com/x")])
        state.search.text = "zzz"          // parked, but never revealed
        #expect(!state.search.isActive)
        #expect(state.displayFlows.count == 1)
    }

    @Test func dismissClearsTheNeedle() {
        var search = FlowSearch()
        search.isPresented = true
        search.text = "orders"
        search.engineMatches = [UUID()]
        search.staleCount = 4
        search.dismiss()
        #expect(search.text.isEmpty)
        #expect(search.engineMatches == nil)
        #expect(search.staleCount == 0)
        #expect(!search.isActive)
    }

    // MARK: Engine scopes

    /// Bodies are stripped out of the window's copies (`upsertFlow`), so a body needle
    /// cannot be answered here at all — and until the answer lands, nothing matches,
    /// rather than the unfiltered capture flashing between keystroke and result.
    @Test func engineScopeMatchesNothingUntilAnAnswerLands() {
        let flow = Fixtures.flow(url: "https://a.com/x")
        var state = state([flow])
        state.search.isPresented = true
        state.search.scope = .body
        state.search.text = "token"
        #expect(state.displayFlows.isEmpty)

        state.search.engineMatches = [flow.id]
        #expect(state.displayFlows.map(\.id) == [flow.id])
    }

    /// "Asked, nothing matched" is a different fact from "no answer yet", and the
    /// engine query is built from the sidebar category so the scan is narrow before
    /// any payload is hydrated off disk.
    @Test func engineQueryCarriesTheNeedleAndTheCategory() {
        var search = FlowSearch()
        search.isPresented = true
        search.scope = .body
        search.text = "order-42"
        let query = search.engineQuery(category: .host("b.com"))
        #expect(query?.bodyContains == "order-42")
        #expect(query?.host == "b.com")
        #expect(query?.headerContains == nil)

        search.scope = .headers
        #expect(search.engineQuery(category: .errors)?.headerContains == "order-42")
        #expect(search.engineQuery(category: .errors)?.onlyErrors == true)
    }

    /// The URL scope is answered locally, so it must never produce a query.
    @Test func urlScopeAsksTheEngineNothing() {
        var search = FlowSearch()
        search.isPresented = true
        search.text = "orders"
        #expect(search.engineQuery(category: .all) == nil)
    }

    // MARK: Staleness — an engine answer is a snapshot

    /// An engine-scope result is not re-run on every capture batch (a body needle
    /// would put a disk read per flow on the live path), so what it cannot account for
    /// is counted and offered — never silently dropped.
    @Test func flowsArrivingAfterAnAnswerAreCounted() {
        var state = state([])
        state.search.isPresented = true
        state.search.scope = .body
        state.search.text = "token"
        state.search.engineMatches = []

        let fresh = Fixtures.flow(url: "https://a.com/1")
        state.noteFlowsArrivedDuringSearch([fresh])
        state.recordFlows([fresh])
        #expect(state.search.staleCount == 1)

        // The same exchange updating (pending → completed) is not a new flow: only
        // ids the window hasn't seen went unconsidered by the search.
        state.noteFlowsArrivedDuringSearch([fresh])
        state.recordFlows([fresh])
        #expect(state.search.staleCount == 1)
    }

    /// The URL scope re-filters every render, so it is live by construction and must
    /// never accumulate a staleness count to act on.
    @Test func urlScopeNeverGoesStale() {
        var state = state([])
        state.search.isPresented = true
        state.search.text = "orders"

        let fresh = Fixtures.flow(url: "https://a.com/orders/9")
        state.noteFlowsArrivedDuringSearch([fresh])
        state.recordFlows([fresh])
        #expect(state.search.staleCount == 0)
        #expect(state.displayFlows.map(\.id) == [fresh.id])
    }

    // MARK: Reducer wiring

    @MainActor
    @Test func commandOpensTheBarAndDismissClearsIt() async {
        let store = TestStore(initialState: CaptureFeature.State()) { CaptureFeature() } withDependencies: {
            $0.continuousClock = TestClock()
        }
        await store.send(.searchToggled) { $0.search.isPresented = true }
        await store.send(.searchTextChanged("orders")) { $0.search.text = "orders" }
        await store.send(.searchDismissed) { $0.search.dismiss() }
    }

    /// A slow body scan can outlive the keystroke that started it; landing late must
    /// not replace the answer to the question actually being asked.
    @MainActor
    @Test func aResultForAStaleNeedleIsDropped() async {
        let clock = TestClock()
        let store = TestStore(initialState: CaptureFeature.State()) { CaptureFeature() } withDependencies: {
            $0.continuousClock = clock
            // The engine's answer is irrelevant here — what's under test is which
            // answers the reducer keeps.
            $0.proxyClient.recentFlowsMatching = { _, _ in [] }
        }
        store.exhaustivity = .off
        await store.send(.searchToggled)
        await store.send(.searchScopeChanged(.body))
        await store.send(.searchTextChanged("new-needle"))
        await clock.advance(by: CaptureFeature.searchDebounce)
        await store.skipReceivedActions()   // the real answer for "new-needle" lands
        let settled = store.state.search.engineMatches

        let late = UUID()
        await store.send(.searchResultsLoaded(ids: [late], needle: "old-needle", scope: .body))
        #expect(store.state.search.engineMatches == settled)
        #expect(store.state.search.engineMatches?.contains(late) != true)

        // A scope's answer is dropped the same way, so switching scope mid-scan can't
        // leave the body result labelled as the header one.
        await store.send(.searchResultsLoaded(ids: [late], needle: "new-needle", scope: .headers))
        #expect(store.state.search.engineMatches?.contains(late) != true)

        await store.send(.searchDismissed)
    }

    /// `displayFlowsAreEmpty` is the O(1) probe that picks the empty state; it has to
    /// keep agreeing with `displayFlows` once a needle is involved, because it is the
    /// difference between "no matches" and "no traffic" on screen.
    @Test func emptinessProbeAgreesWithTheFilteredList() {
        var state = state([Fixtures.flow(url: "https://a.com/x")])
        state.search.isPresented = true
        state.search.text = "zzz"
        #expect(state.displayFlowsAreEmpty == state.displayFlows.isEmpty)
        state.search.text = "a.com"
        #expect(state.displayFlowsAreEmpty == state.displayFlows.isEmpty)
    }

    // MARK: Typing into the bar must not cost the capture

    /// The needle is prepared once per rebuild, not once per row.
    ///
    /// The version this replaces recomputed `needle` twice per flow (a
    /// `trimmingCharacters` allocation each) and matched with
    /// `range(of:options:.caseInsensitive)`: 84 ms over a full window, more than once
    /// per keystroke, which is what made the find bar stutter while it had focus. The
    /// bound is loose on purpose — this fails on a return to the per-row shape, not on
    /// a slow machine.
    @Test func filteringAFullWindowIsCheapPerKeystroke() {
        let flows = (0 ..< CaptureFeature.State.displayCap).map {
            Fixtures.flow(url: "https://api.example.com/v1/resource/\($0)/items?page=\($0 % 13)")
        }
        var state = state(flows)
        state.search.isPresented = true
        let start = Date()
        for needle in ["it", "ite", "item", "items", "items?"] { state.search.text = needle }
        let elapsed = Date().timeIntervalSince(start)
        #expect(state.displayFlows.count == CaptureFeature.State.displayCap)
        #expect(elapsed < 1.0, "5 keystrokes over a full window took \(elapsed)s — per-row needle work is back")
    }

    /// A field no row is filtered by must not trigger a rescan. One keystroke writes
    /// `isSearching` as well as `text`, so an unconditional `didSet` scanned twice.
    @Test func nonFilteringFieldsDoNotAffectTheProjection() {
        var search = FlowSearch()
        search.isPresented = true
        search.text = "orders"
        var other = search
        other.isSearching = true
        other.staleCount = 7
        other.outOfWindowMatches = 3
        #expect(!other.affectsProjection(comparedTo: search))

        other.text = "orders " // trims to the same needle: same rows
        #expect(!other.affectsProjection(comparedTo: search))
        other.text = "order"
        #expect(other.affectsProjection(comparedTo: search))
    }

    /// The byte scan is only taken for an ASCII needle; anything else falls back to
    /// Foundation, because case folding outside ASCII is not a bit flip.
    @Test func needleMatcherFoldsASCIIAndDefersOnTheRest() {
        #expect(NeedleMatcher("Orders").contains("https://a.com/ORDERS/1"))
        #expect(NeedleMatcher("orders").contains("https://a.com/Orders/1"))
        #expect(!NeedleMatcher("orders").contains("https://a.com/order/1"))
        #expect(NeedleMatcher("").contains("anything"))
        // Needle longer than the haystack, and an almost-match that must restart.
        #expect(!NeedleMatcher("https://a.com/orders/1/x").contains("https://a.com"))
        #expect(NeedleMatcher("aab").contains("xaaab"))
        // Non-ASCII on both sides.
        #expect(NeedleMatcher("café").contains("https://a.com/CAFÉ"))
        #expect(NeedleMatcher("订单").contains("https://a.com/订单/1"))
        #expect(!NeedleMatcher("订单").contains("https://a.com/orders/1"))
        // An ASCII needle against a non-ASCII haystack still scans bytes correctly.
        #expect(NeedleMatcher("com/").contains("https://a.com/订单"))
    }
}
