import Testing
@testable import LoomProxyCore
import LoomSharedModels
import Foundation

/// A rule or breakpoint can be scoped to *who* made the request, not just what it
/// asked for — "mock this endpoint for the app under test, leave my browser alone",
/// or "break only my phone's calls". The dangerous failure mode is the quiet one: a
/// scoped rule that acts on a client it wasn't meant for. So the rule is fail-closed
/// (unattributed traffic never matches an origin-scoped rule), and the origin has to
/// actually reach the matcher through the forwarding chain.
@Suite struct OriginScopedRulesTests {
    private let url = URL(string: "https://api.example.test/v1/home")!

    private let app = SourceApp(name: "MyApp", bundleID: "com.example.MyApp", pid: 501)
    private let otherApp = SourceApp(name: "Safari", bundleID: "com.apple.Safari", pid: 99)
    private let phone = SourceDevice(ip: "192.168.1.9", kind: .lan, platform: "iOS", client: nil)
    private let thisMac = SourceDevice(ip: "127.0.0.1", kind: .local, platform: "macOS", client: nil)

    // MARK: Matching

    @Test func appScope_matchesByBundleIDOrName_caseInsensitively() {
        let byBundle = RuleMatch(urlPattern: "*", sourceApp: "com.example.myapp")
        let byName = RuleMatch(urlPattern: "*", sourceApp: "myapp")
        let origin = RequestOrigin(app: app, device: thisMac)

        #expect(byBundle.matches(method: "GET", url: url.absoluteString, origin: origin))
        #expect(byName.matches(method: "GET", url: url.absoluteString, origin: origin))
        #expect(!byBundle.matches(method: "GET", url: url.absoluteString,
                                  origin: RequestOrigin(app: otherApp, device: thisMac)))
    }

    @Test func deviceScope_matchesTheDeviceIP() {
        let match = RuleMatch(urlPattern: "*", deviceIP: "192.168.1.9")
        #expect(match.matches(method: "GET", url: url.absoluteString, origin: RequestOrigin(device: phone)))
        #expect(!match.matches(method: "GET", url: url.absoluteString, origin: RequestOrigin(device: thisMac)))
    }

    /// The safety property. An app-scoped rule must not act on traffic Loom couldn't
    /// attribute — a LAN device has no local pid, so "no app" is common, not exotic,
    /// and treating unknown as "matches" would apply the rule to every client.
    @Test func originScope_failsClosedOnUnattributedTraffic() {
        let appScoped = RuleMatch(urlPattern: "*", sourceApp: "com.example.MyApp")
        #expect(!appScoped.matches(method: "GET", url: url.absoluteString, origin: nil))
        #expect(!appScoped.matches(method: "GET", url: url.absoluteString, origin: RequestOrigin()))
        #expect(!appScoped.matches(method: "GET", url: url.absoluteString, origin: RequestOrigin(device: phone)),
                "a device with no resolvable app is not this app")
        // And a rule that scopes nothing is unaffected by a missing origin.
        #expect(RuleMatch(urlPattern: "*").matches(method: "GET", url: url.absoluteString, origin: nil))
    }

    @Test func originAndURLPredicatesAND_together() {
        let match = RuleMatch(urlPattern: "https://api.example.test/v1/*", sourceApp: "com.example.MyApp")
        let origin = RequestOrigin(app: app, device: thisMac)
        #expect(match.matches(method: "GET", url: url.absoluteString, origin: origin))
        #expect(!match.matches(method: "GET", url: "https://other.test/v1/home", origin: origin),
                "right app, wrong URL")
    }

    @Test func constrainsOrigin_reportsWhetherTheScopeIsSet() {
        #expect(!RuleMatch(urlPattern: "*").constrainsOrigin)
        #expect(!RuleMatch(urlPattern: "*", sourceApp: "").constrainsOrigin, "an empty string is not a scope")
        #expect(RuleMatch(urlPattern: "*", sourceApp: "com.example.MyApp").constrainsOrigin)
        #expect(RuleMatch(urlPattern: "*", deviceIP: "192.168.1.9").constrainsOrigin)
    }

    @Test func tolerantDecode_ofARuleSavedBeforeOriginScopesExisted() throws {
        let json = Data(#"{"urlPattern":"https://x.test/*","isRegex":false,"methods":[]}"#.utf8)
        let match = try JSONDecoder().decode(RuleMatch.self, from: json)
        #expect(match.sourceApp == nil)
        #expect(match.deviceIP == nil)
        #expect(!match.constrainsOrigin)
        // …and a scoped rule survives a round trip through the persisted form.
        let scoped = RuleMatch(urlPattern: "*", sourceApp: "com.example.MyApp", deviceIP: "192.168.1.9")
        let restored = try JSONDecoder().decode(RuleMatch.self, from: try JSONEncoder().encode(scoped))
        #expect(restored == scoped)
    }

    // MARK: Reaching the matcher — the plumbing, not just the predicate

    @Test func theForwarderAppliesARuleOnlyToTheScopedApp() async throws {
        let upstream = OriginStubUpstream()
        let config = RulesConfig(fileURL: nil)
        config.setEnabled(true)
        config.add(TrafficRule(
            name: "mock for the app under test",
            match: RuleMatch(urlPattern: "*", sourceApp: "com.example.MyApp"),
            actions: RuleActions(route: .mock(MockResponseAction(statusCode: 418, bodyText: "teapot")))
        ))
        let forwarder = RuleApplyingForwarder(base: upstream, rules: config)

        // The scoped app gets the mock…
        let mine = try await forwarder
            .forwardStream(method: "GET", url: url, headers: [], body: .bytes(nil),
                           origin: RequestOrigin(app: app, device: thisMac))
            .collect()
        #expect(mine.statusCode == 418)
        #expect(await upstream.callCount == 0, "a mock must not reach upstream")

        // …another app's identical request does not.
        let theirs = try await forwarder
            .forwardStream(method: "GET", url: url, headers: [], body: .bytes(nil),
                           origin: RequestOrigin(app: otherApp, device: thisMac))
            .collect()
        #expect(theirs.statusCode == 200)
        #expect(await upstream.callCount == 1, "the unscoped client's request went to the real upstream")
    }

    /// Buffered and streaming forwarding must reach the same verdict about an
    /// origin-scoped rule — invariant I3 (one rule choke point) with an origin.
    @Test func bufferedAndStreamingAgreeOnAnOriginScopedRule() async throws {
        let config = RulesConfig(fileURL: nil)
        config.setEnabled(true)
        config.add(TrafficRule(
            name: "block the phone",
            match: RuleMatch(urlPattern: "*", deviceIP: "192.168.1.9"),
            actions: RuleActions(route: .block)
        ))
        let forwarder = RuleApplyingForwarder(base: OriginStubUpstream(), rules: config)
        let origin = RequestOrigin(device: phone)

        // Streaming path (no body-touching rule → streams), then the buffered fold.
        let streamed = try await forwarder
            .forwardStream(method: "GET", url: url, headers: [], body: .bytes(nil), origin: origin)
            .collect()
        let buffered = try await forwarder
            .forwardStream(method: "GET", url: url, headers: [], body: .bytes(Data("x".utf8)), origin: origin)
            .collect()
        #expect(streamed.statusCode == 403)
        #expect(buffered.statusCode == 403)
    }

    @Test func aBreakpointCanBeScopedToOneApp() async throws {
        let store = BreakpointStore(timeout: 0.2)
        store.arm(Breakpoint(
            match: RuleMatch(urlPattern: "*", sourceApp: "com.example.MyApp"), onRequest: true
        ))
        #expect(store.firstMatch(method: "GET", url: url.absoluteString, phase: .request,
                                 origin: RequestOrigin(app: app)) != nil)
        #expect(store.firstMatch(method: "GET", url: url.absoluteString, phase: .request,
                                 origin: RequestOrigin(app: otherApp)) == nil)
        #expect(store.firstMatch(method: "GET", url: url.absoluteString, phase: .request, origin: nil) == nil,
                "unattributed traffic must not be held by an app-scoped breakpoint")
    }

    /// A replay inherits the origin of the flow it re-sends, so replaying an app's
    /// request behaves like that app's request. Otherwise an agent that mocks "my
    /// app's /orders" and then replays one of those requests would watch its own rule
    /// not apply, with nothing to explain why.
    @Test func aReplayInheritsTheOriginOfTheFlowItResends() async throws {
        let upstream = OriginStubUpstream()
        let engine = ProxyEngine(forwarder: upstream, caStore: InMemoryCAStore())
        await engine.setRulesEnabled(true)
        try await engine.addRule(TrafficRule(
            name: "mock for the app under test",
            match: RuleMatch(urlPattern: "*", sourceApp: "com.example.MyApp"),
            actions: RuleActions(route: .mock(MockResponseAction(statusCode: 418, bodyText: "teapot")))
        ))

        let captured = Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: url.absoluteString, headers: []),
            startedAt: Date(),
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date()),
            sourceApp: app,
            sourceDevice: thisMac
        )
        let replayed = try await engine.replay(flow: captured, overrides: .none)
        #expect(replayed.statusCode == 418, "the app-scoped rule applied to the replay")
        #expect(replayed.appliedRules?.count == 1)

        // A flow with no attribution replays as unattributed: the scoped rule stays out.
        let anonymous = Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: url.absoluteString, headers: []),
            startedAt: Date(),
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date())
        )
        let plainReplay = try await engine.replay(flow: anonymous, overrides: .none)
        #expect(plainReplay.statusCode == 200)
        #expect(plainReplay.appliedRules == nil)

        await engine.stopForTest()
    }
}

private actor OriginStubUpstream: UpstreamForwarding {
    var callCount = 0

    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        callCount += 1
        return ForwardResult(statusCode: 200, headers: [], body: Data("upstream".utf8))
    }
}
