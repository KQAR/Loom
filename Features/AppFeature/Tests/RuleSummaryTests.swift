import Foundation
import LoomSharedModels
import Testing

@testable import AppFeature

/// The rules list row is the human's only overview of what an agent has written,
/// and its failure mode is silent omission: a rule whose action has no badge
/// renders exactly like a rule that does nothing.
@Suite struct RuleSummaryTests {
    private func rule(_ actions: RuleActions) -> TrafficRule {
        TrafficRule(name: "r", match: RuleMatch(urlPattern: "https://api.example.com/v1/home"), actions: actions)
    }

    @Test func routeBadges_nameEveryRoute() {
        #expect(RuleSummary.actionBadges(for: rule(RuleActions(route: .block))) == ["BLOCK"])
        #expect(RuleSummary.actionBadges(for: rule(RuleActions(route: .mock(MockResponseAction())))) == ["MOCK"])
        #expect(RuleSummary.actionBadges(for: rule(RuleActions(
            route: .mapLocal(MapLocalAction(path: "/tmp/x.json"))))) == ["MAP LOCAL"])
        #expect(RuleSummary.actionBadges(for: rule(RuleActions(
            route: .mapRemote(MapRemoteAction(destination: "http://127.0.0.1:3001"))))) == ["MAP REMOTE"])
        #expect(RuleSummary.actionBadges(for: rule(RuleActions(route: .passthrough))).isEmpty)
    }

    /// The gap this file was written for. A find/replace rule is what the editor's
    /// two Modify segments produce — the shape a human is most likely to author by
    /// hand — and it used to carry no badge at all.
    @Test func substitutions_areBadged() {
        let actions = RuleActions(
            route: .passthrough,
            requestSubstitutions: [SubstitutionRule(field: .body, match: "a", replacement: "b")],
            responseSubstitutions: [
                SubstitutionRule(field: .body, match: "c", replacement: "d"),
                SubstitutionRule(field: .header(), match: "e", replacement: "f"),
            ]
        )
        #expect(RuleSummary.actionBadges(for: rule(actions)) == ["SUB REQ", "SUB RES ×2"])
    }

    @Test func emptySubstitutionRows_areNotBadged() {
        let actions = RuleActions(
            route: .block,
            requestSubstitutions: [SubstitutionRule(field: .body, match: "", replacement: "ignored")]
        )
        #expect(RuleSummary.actionBadges(for: rule(actions)) == ["BLOCK"], "an unfilled row is not an action")
    }

    @Test func rewritesAndDelay_areBadged() {
        let actions = RuleActions(
            route: .passthrough,
            rewriteRequest: RequestRewriteAction(method: "PUT"),
            rewriteResponse: ResponseRewriteAction(statusCode: 503),
            delayMilliseconds: 250
        )
        #expect(RuleSummary.actionBadges(for: rule(actions)) == ["REQ", "RES", "DELAY 250ms"])
    }

    /// Origin scope fails closed, so an app-scoped rule that never fires looks
    /// broken rather than scoped — the row has to say which it is.
    @Test func originScope_isBadgedWithTheValueInTheTooltip() {
        var scoped = rule(RuleActions(route: .block))
        scoped.match.sourceApp = "com.example.MyApp"
        scoped.match.deviceIP = "192.168.1.9"
        let badges = RuleSummary.scopeBadges(for: scoped)
        #expect(badges.map(\.text) == ["APP", "DEVICE"])
        #expect(badges[0].detail.contains("com.example.MyApp"))
        #expect(badges[1].detail.contains("192.168.1.9"))
    }

    @Test func unscopedRule_hasNoScopeBadges() {
        #expect(RuleSummary.scopeBadges(for: rule(RuleActions(route: .block))).isEmpty)
    }

    @Test func patternText_showsMethodsHostAndPattern() {
        var scoped = rule(RuleActions(route: .block))
        scoped.match.methods = ["get", "post"]
        scoped.match.hostPattern = "*.example.com"
        #expect(RuleSummary.patternText(for: scoped)
            == "GET/POST host:*.example.com https://api.example.com/v1/home")
    }

    @Test func patternText_marksARegexPattern() {
        var regex = rule(RuleActions(route: .block))
        regex.match.style = .regex
        regex.match.urlPattern = "://api\\.example\\.com/"
        #expect(RuleSummary.patternText(for: regex) == "/://api\\.example\\.com//")
    }
}
