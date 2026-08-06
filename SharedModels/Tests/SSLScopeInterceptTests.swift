import Foundation
import Testing

@testable import LoomSharedModels

/// The whitelist scope's two new questions: *why* a host isn't decrypted, and what
/// it takes to start decrypting it.
///
/// Both exist because the answer used to be a bare `false` — indistinguishable from
/// "interception is off", from "you excluded it", and from "there is no CA" — and a
/// blind-tunnelled host leaves nothing on any other surface to tell them apart.
@Suite struct SSLScopeInterceptTests {
    // MARK: passthroughReason

    @Test func disabledScope_reportsInterceptionOff_evenWithMatchingInclude() {
        let scope = SSLScope(enabled: false, include: ["api.example.com"])
        #expect(scope.passthroughReason(host: "api.example.com") == .interceptionDisabled)
        #expect(!scope.shouldIntercept(host: "api.example.com"))
    }

    @Test func emptyInclude_isNotInScope_ratherThanDisabled() {
        let scope = SSLScope(enabled: true)
        // Not the shipping default (that is `["*"]`), but reachable — someone removed
        // every include entry. The distinction is the point: one is a switch, the other
        // is a list, and they need different words on every surface.
        #expect(scope.passthroughReason(host: "api.example.com") == .notInScope)
    }

    @Test func excludeBeatsInclude_andNamesTheGlob() {
        let scope = SSLScope(enabled: true, include: ["*"], exclude: ["*.google.com"])
        #expect(scope.passthroughReason(host: "dl.google.com") == .excluded)
        #expect(scope.excludeGlob(matching: "dl.google.com") == "*.google.com")
        #expect(scope.excludeGlob(matching: "api.example.com") == nil)
    }

    @Test func interceptedHost_hasNoReason() {
        let scope = SSLScope(enabled: true, include: ["*.example.com"])
        #expect(scope.passthroughReason(host: "api.example.com") == nil)
        #expect(scope.shouldIntercept(host: "api.example.com"))
    }

    // MARK: intercept(host:)

    @Test func intercept_addsIncludeAndTurnsInterceptionOn() {
        var scope = SSLScope.disabled
        let outcome = scope.intercept(host: "api.example.com")

        #expect(scope.enabled, "an include entry on an off scope would look like it did nothing")
        #expect(scope.include == ["api.example.com"])
        #expect(outcome.enabledInterception)
        #expect(!outcome.alreadyIncluded)
        #expect(outcome.effective)
        #expect(scope.shouldIntercept(host: "api.example.com"))
    }

    @Test func intercept_alreadyCoveredByGlob_changesNothing() {
        var scope = SSLScope(enabled: true, include: ["*.example.com"])
        let outcome = scope.intercept(host: "api.example.com")

        #expect(outcome.alreadyIncluded)
        #expect(!outcome.enabledInterception)
        #expect(scope.include == ["*.example.com"], "no duplicate entry for a host a glob already covers")
        #expect(outcome.effective)
    }

    @Test func intercept_dropsAnExactExclude_becauseThatIsTheReversalBeingAsked() {
        var scope = SSLScope(enabled: true, include: [], exclude: ["api.example.com"])
        let outcome = scope.intercept(host: "API.example.com")

        #expect(outcome.removedExcludes == ["api.example.com"], "case-insensitive, like every other host comparison")
        #expect(scope.exclude.isEmpty)
        #expect(outcome.effective)
        #expect(scope.shouldIntercept(host: "api.example.com"))
    }

    /// The failure this whole surface exists to prevent: the write lands, the include
    /// list shows the host, and the traffic stays unread because a glob outranks it.
    @Test func intercept_shadowedByWildcardExclude_isReportedAsIneffective() {
        var scope = SSLScope(enabled: true, exclude: ["*.example.com"])
        let outcome = scope.intercept(host: "api.example.com")

        #expect(scope.include.contains("api.example.com"))
        #expect(outcome.shadowedByExclude == "*.example.com")
        #expect(!outcome.effective)
        #expect(!scope.shouldIntercept(host: "api.example.com"), "the reported verdict matches the scope's own")
    }

    @Test func intercept_leavesSomeoneElsesGlobAlone() {
        var scope = SSLScope(enabled: true, exclude: ["*.example.com"])
        _ = scope.intercept(host: "api.example.com")
        #expect(scope.exclude == ["*.example.com"], "a glob is someone else's rule; only an exact entry is reversed")
    }

    // MARK: TunneledHost

    @Test func interceptable_isFalseForReasonsNoScopeChangeFixes() {
        func entry(_ reason: TunnelReason) -> TunneledHost {
            TunneledHost(host: "h", port: 443, firstSeen: Date(), lastSeen: Date(), reason: reason)
        }
        #expect(entry(.notInScope).interceptable)
        #expect(entry(.interceptionDisabled).interceptable)
        #expect(entry(.excluded).interceptable)
        #expect(!entry(.notTLSOrHTTP).interceptable, "an SSH tunnel does not become readable by being listed")
        #expect(!entry(.noCertificateAuthority).interceptable)
        #expect(!entry(.leafMintFailed).interceptable)
    }

    /// Every reason has to be answerable by a renderer, so a new case can't be added
    /// and silently fall through to "unknown" on a surface.
    @Test func everyReasonIsInterceptableOrNot() {
        for reason in TunnelReason.allCases {
            let entry = TunneledHost(host: "h", port: 443, firstSeen: Date(), lastSeen: Date(), reason: reason)
            #expect(entry.interceptable == (
                reason == .notInScope || reason == .interceptionDisabled || reason == .excluded
            ))
        }
    }
}
