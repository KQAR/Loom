import ComposableArchitecture
import Foundation
import LoomSharedModels
import Testing
@testable import AppFeature

/// The Hosts section as a tree, and the order its rows come in.
///
/// Two things the sidebar now says that it used to leave to the operator: which
/// hosts the SSL scope decrypts (they float up and carry a marker), and which
/// hosts belong together (folded under their registrable domain). Both are
/// computed once in `refreshSidebarRows` and read by the view, so both are pinned
/// here rather than in the view.
@Suite struct SidebarHostTreeTests {
    /// Record the flows *and* set the counts the engine would report for them — the
    /// aggregates are the engine's, over everything retained, so the window never
    /// derives them itself (see `FlowAggregates`).
    private func state(hosts: [String], scope: SSLScope = .disabled, pinned: Set<String> = []) -> CaptureFeature.State {
        var state = CaptureFeature.State()
        var aggregates = FlowAggregates()
        for flow in hosts.map({ Fixtures.flow(url: "https://\($0)/") }) {
            state.recordFlow(flow)
            aggregates.contribute(flow)
        }
        state.aggregates = aggregates
        state.sslScope = scope
        state.pinnedHosts = pinned
        return state
    }

    // MARK: - Grouping

    @Test(arguments: [
        ("api.example.com", "example.com"),
        ("example.com", "example.com"),
        ("a.b.c.example.com", "example.com"),
        ("www.bbc.co.uk", "bbc.co.uk"),
        ("shop.example.com.au", "example.com.au"),
        ("co.uk", "co.uk"),
        ("localhost", "localhost"),
        ("10.0.34.87", "10.0.34.87"),
        ("[::1]", "[::1]"),
        ("intranet", "intranet"),
    ])
    func registrableDomain(host: String, domain: String) {
        #expect(HostGrouping.domain(of: host) == domain)
    }

    @Test func membershipIsOnALabelBoundary() {
        #expect(HostGrouping.isWithin("api.example.com", domain: "example.com"))
        #expect(HostGrouping.isWithin("example.com", domain: "example.com"))
        #expect(!HostGrouping.isWithin("notexample.com", domain: "example.com"))
        #expect(!HostGrouping.isWithin("example.com", domain: "api.example.com"))
    }

    @Test func hostsFoldUnderTheirDomain() throws {
        let s = state(hosts: ["api.example.com", "cdn.example.com", "example.com", "other.test", "api.example.com"])
        let groups = s.hostGroups
        #expect(groups.map(\.domain) == ["example.com", "other.test"])
        try #require(groups.count == 2)
        let example = groups[0]
        #expect(example.hosts.map(\.host) == ["api.example.com", "cdn.example.com", "example.com"])
        #expect(example.count == 4)
        #expect(groups[1].hosts.count == 1) // drawn flat by the view
    }

    @Test func aDomainRowSelectsEverythingUnderIt() {
        var s = state(hosts: ["api.example.com", "example.com", "notexample.com", "other.test"])
        s.selection = [.domain("example.com")]
        #expect(Set(s.displayFlows.compactMap(\.host)) == ["api.example.com", "example.com"])
        // Same dimension as a host: a domain plus one of its own hosts is a union,
        // and a domain plus a foreign host is either.
        s.selection = [.domain("example.com"), .host("other.test")]
        #expect(Set(s.displayFlows.compactMap(\.host)) == ["api.example.com", "example.com", "other.test"])
    }

    // MARK: - Order and marker

    @Test func decryptedHostsFloatAboveTheRest() {
        let scope = SSLScope(enabled: true, include: ["m.test"], exclude: [])
        let s = state(hosts: ["a.test", "m.test", "z.test"], scope: scope)
        #expect(s.hosts.map(\.host) == ["m.test", "a.test", "z.test"])
        #expect(s.hosts.map(\.intercepted) == [true, false, false])
    }

    @Test func aPinOutranksTheScope() {
        // A pin is the operator's explicit "keep this at the top"; a scope change
        // that could bury it would make pinning meaningless.
        let scope = SSLScope(enabled: true, include: ["m.test"], exclude: [])
        let s = state(hosts: ["a.test", "m.test", "z.test"], scope: scope, pinned: ["z.test"])
        #expect(s.hosts.map(\.host) == ["z.test", "m.test", "a.test"])
    }

    @Test func aDisabledScopeDecryptsNothing() {
        let s = state(hosts: ["a.test"], scope: SSLScope(enabled: false, include: ["*"], exclude: []))
        #expect(s.hosts.map(\.intercepted) == [false])
    }

    @Test func anExcludeBeatsAnInclude() {
        let scope = SSLScope(enabled: true, include: ["*"], exclude: ["*.example.com"])
        let s = state(hosts: ["api.example.com", "other.test"], scope: scope)
        #expect(s.hosts.map(\.host) == ["other.test", "api.example.com"])
        #expect(s.hosts.first(where: { $0.host == "api.example.com" })?.intercepted == false)
    }

    @Test func aGroupFloatsWhenAnyMemberIsDecrypted() throws {
        let scope = SSLScope(enabled: true, include: ["api.zed.test"], exclude: [])
        let s = state(hosts: ["a.alpha.test", "b.alpha.test", "api.zed.test", "www.zed.test"], scope: scope)
        #expect(s.hostGroups.map(\.domain) == ["zed.test", "alpha.test"])
        let zed = try #require(s.hostGroups.first)
        #expect(zed.intercepted)
        #expect(zed.interceptedCount == 1)
        // Within the group the decrypted host leads too.
        #expect(zed.hosts.map(\.host) == ["api.zed.test", "www.zed.test"])
    }

    @Test func aScopeChangeReordersWithoutNewFlows() {
        var s = state(hosts: ["a.test", "z.test"])
        #expect(s.hosts.map(\.host) == ["a.test", "z.test"])
        s.sslScope = SSLScope(enabled: true, include: ["z.test"], exclude: [])
        #expect(s.hosts.map(\.host) == ["z.test", "a.test"])
    }

    // MARK: - Search pushdown

    @Test func aDomainIsNeverPushedDownToTheEngine() {
        // `FlowQuery.host` is exact-or-glob and cannot say "this suffix, apex
        // included", so a domain row stays with the window's predicate.
        var search = FlowSearch()
        search.isPresented = true
        search.text = "token"
        search.scope = .headers
        #expect(search.engineQuery(selection: [.domain("example.com")])?.host == nil)
        // And a host beside a domain is one member of an OR — pushing it alone
        // would drop the domain's rows.
        #expect(search.engineQuery(selection: [.domain("example.com"), .host("other.test")])?.host == nil)
        #expect(search.engineQuery(selection: [.host("other.test")])?.host == "other.test")
    }
}

/// The scope reaches the capture child through the parent, and through nothing
/// else — `SetupFeature` owns it, `CaptureFeature` sorts by it.
@Suite struct SidebarScopeProjectionTests {
    @MainActor
    @Test func aScopeLoadedIntoSetupReachesTheCapture() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }
        let scope = SSLScope(enabled: true, include: ["*.example.com"], exclude: [])
        await store.send(.setup(.sslScopeLoaded(scope))) {
            $0.setupState.sslScope = scope
            $0.setupState.sslEnabled = true
            $0.capture.sslScope = scope
        }
    }
}
