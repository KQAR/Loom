import Foundation
import LoomSharedModels
import Testing
@testable import AppFeature

/// Live validation of the console's Add-endpoint form. Tested here rather than through
/// the view because the interesting cases are the ones nobody clicks through by hand: a
/// bare host, a query on an origin, and the difference between a blank port and a typed
/// zero.
@Suite struct ReverseProxyDraftTests {
    // MARK: Port

    /// Blank is a legitimate "any free port" — the OS picks and the card reports which
    /// one it got — so an untouched field must not accuse the human of anything.
    @Test func aBlankPortIsNotAProblem() {
        let draft = ReverseProxyDraft(port: "", upstream: "https://api.example.com")
        #expect(draft.portProblem == nil)
        #expect(draft.canSubmit)
        #expect(draft.submittedPort == 0, "blank submits the engine's any-free-port sentinel")
    }

    @Test func aNonNumericPortIsRefusedWhileTyping() {
        let draft = ReverseProxyDraft(port: "90x", upstream: "https://api.example.com")
        #expect(draft.portProblem != nil)
        #expect(!draft.canSubmit)
    }

    /// A port that can never bind is worth saying immediately rather than after a round
    /// trip to the engine.
    @Test func aPortOutsideTheLegalRangeIsRefused() {
        #expect(ReverseProxyDraft(port: "70000", upstream: "https://a.example.com").portProblem != nil)
        #expect(ReverseProxyDraft(port: "-1", upstream: "https://a.example.com").portProblem != nil)
    }

    /// A hand-typed `0` must not sail through as the any-free-port sentinel: the human
    /// meant a port and 0 isn't one, so it is refused rather than silently reinterpreted.
    @Test func aTypedZeroIsRefusedRatherThanReadAsPickOneForMe() {
        let draft = ReverseProxyDraft(port: "0", upstream: "https://api.example.com")
        #expect(draft.portProblem != nil)
        #expect(!draft.canSubmit)
    }

    @Test func aLegalPortSubmitsAsTyped() {
        let draft = ReverseProxyDraft(port: " 9200 ", upstream: "https://api.example.com")
        #expect(draft.portProblem == nil)
        #expect(draft.submittedPort == 9200)
    }

    // MARK: Upstream

    @Test func anEmptyUpstreamBlocksSubmitWithoutShoutingAtAnEmptyField() {
        let draft = ReverseProxyDraft()
        #expect(draft.upstreamProblem == nil)
        #expect(!draft.canSubmit, "the upstream is the one required field")
    }

    /// The case that makes live validation worth having: a bare host parses as a *path*
    /// with no scheme, so it would be accepted by anything doing a shallow check and
    /// then forward nowhere.
    @Test func aBareHostIsRejectedAndTheMessageSaysWhy() throws {
        let problem = try #require(ReverseProxyDraft(upstream: "api.example.com").upstreamProblem)
        #expect(problem.contains("http://"))
    }

    @Test func aQueryOnAnOriginIsRejected() {
        #expect(ReverseProxyDraft(upstream: "https://api.example.com?a=1").upstreamProblem != nil)
    }

    @Test func aValidUpstreamPassesAndSubmitsTrimmed() {
        let draft = ReverseProxyDraft(upstream: "  https://api.example.com/v2  ")
        #expect(draft.upstreamProblem == nil)
        #expect(draft.canSubmit)
        #expect(draft.submittedUpstream == "https://api.example.com/v2")
    }

    /// The form defers to `ReverseProxyEndpoint.normalizedUpstream` — the same function
    /// `create_reverse_proxy` calls — so the two surfaces can't disagree about what a
    /// usable upstream is. This pins the delegation, not a copy of the rule.
    @Test func theUpstreamRuleIsTheEnginesOwn() {
        let raw = "ftp://api.example.com"
        let engineRefused: Bool
        do {
            _ = try ReverseProxyEndpoint.normalizedUpstream(raw)
            engineRefused = false
        } catch {
            engineRefused = true
        }
        #expect(engineRefused)
        #expect(ReverseProxyDraft(upstream: raw).upstreamProblem != nil)
    }
}
