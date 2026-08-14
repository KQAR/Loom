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
        // Shipping default: `include` starts empty and nothing is decrypted until
        // named. The distinction is the point: one is a switch, the other is a
        // list, and they need different words on every surface.
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

    // MARK: stopIntercepting — the inverse (0.0.27)

    /// Under a whitelist the inverse of "decrypt this" is dropping the include entry.
    /// No exclude is added: an exclude is a standing carve-out that would outlive the
    /// entry it answered, so a later `intercept(host:)` would appear to succeed and
    /// change nothing.
    @Test func stopIntercepting_dropsTheEntryWithoutLeavingACarveOut() {
        var scope = SSLScope(enabled: true, include: ["api.test", "other.test"])
        let outcome = scope.stopIntercepting(host: "api.test")
        #expect(outcome.removedIncludes == ["api.test"])
        #expect(outcome.addedExclude == false)
        #expect(outcome.shadowedByInclude == nil)
        #expect(scope.include == ["other.test"])
        #expect(scope.exclude == [])
        #expect(!scope.shouldIntercept(host: "api.test"))
        #expect(scope.shouldIntercept(host: "other.test"))
    }

    /// Case-insensitively, because DNS is and nothing normalizes what a client sent.
    @Test func stopIntercepting_matchesTheEntryCaseInsensitively() {
        var scope = SSLScope(enabled: true, include: ["API.Test"])
        _ = scope.stopIntercepting(host: "api.test")
        #expect(scope.include == [])
    }

    /// The one case removal cannot finish: a glob someone else wrote still covers the
    /// host. Narrowing that glob is not this call's business, so it adds the exclude —
    /// and says it did, because the resulting scope now holds a carve-out that a later
    /// re-add has to undo.
    @Test func stopIntercepting_addsAnExcludeOnlyWhenAGlobStillCovers() {
        var scope = SSLScope(enabled: true, include: ["*.corp"])
        let outcome = scope.stopIntercepting(host: "api.corp")
        #expect(outcome.removedIncludes == [])
        #expect(outcome.shadowedByInclude == "*.corp")
        #expect(outcome.addedExclude)
        #expect(scope.include == ["*.corp"], "someone else's glob stands")
        #expect(scope.exclude == ["api.corp"])
        #expect(!scope.shouldIntercept(host: "api.corp"))
        #expect(scope.shouldIntercept(host: "other.corp"), "and only that host is carved out")
    }

    /// Both mechanisms at once: an exact entry *and* a glob. Dropping the entry alone
    /// would leave the host decrypted, which is the failure `effective` is about.
    @Test func stopIntercepting_handlesAnEntryAndAGlobTogether() {
        var scope = SSLScope(enabled: true, include: ["api.corp", "*.corp"])
        let outcome = scope.stopIntercepting(host: "api.corp")
        #expect(outcome.removedIncludes == ["api.corp"])
        #expect(outcome.addedExclude)
        #expect(!scope.shouldIntercept(host: "api.corp"))
    }

    /// Idempotent: stopping twice must not stack duplicate excludes.
    @Test func stopIntercepting_isIdempotent() {
        var scope = SSLScope(enabled: true, include: ["*.corp"])
        _ = scope.stopIntercepting(host: "api.corp")
        let second = scope.stopIntercepting(host: "api.corp")
        #expect(second.addedExclude == false)
        #expect(scope.exclude == ["api.corp"])
    }

    /// The row menu's "Pass Through `*.parent`" hands a glob, not a hostname.
    /// Matching that string as a hostname never finds the literal include entries
    /// it covers, so those have to be dropped explicitly.
    @Test func stopIntercepting_aGlobDropsTheLiteralHostsItCovers() {
        var scope = SSLScope(enabled: true, include: ["api.example.com", "cdn.example.com", "other.test"])
        let outcome = scope.stopIntercepting(host: "*.example.com")
        #expect(Set(outcome.removedIncludes) == ["api.example.com", "cdn.example.com"])
        #expect(outcome.addedExclude == false)
        #expect(scope.include == ["other.test"])
        #expect(!scope.shouldIntercept(host: "api.example.com"))
        #expect(scope.shouldIntercept(host: "other.test"))
    }

    /// A wider include glob still standing (`*`) is not this call's to narrow, so
    /// the glob argument becomes the exclude that punches the hole.
    @Test func stopIntercepting_aGlobStillCarvesOutOfAWiderInclude() {
        var scope = SSLScope(enabled: true, include: ["*", "api.example.com"])
        let outcome = scope.stopIntercepting(host: "*.example.com")
        #expect(outcome.removedIncludes == ["api.example.com"])
        #expect(outcome.shadowedByInclude == "*")
        #expect(outcome.addedExclude)
        #expect(scope.include == ["*"])
        #expect(scope.exclude == ["*.example.com"])
        #expect(!scope.shouldIntercept(host: "api.example.com"))
        #expect(scope.shouldIntercept(host: "other.test"))
    }

    /// And it round-trips with `intercept`, which is the loop a human clicking Decrypt
    /// and then Stop Decrypting actually walks.
    @Test func interceptAndStop_roundTrip() {
        var scope = SSLScope(enabled: true, include: [])
        _ = scope.intercept(host: "api.test")
        #expect(scope.shouldIntercept(host: "api.test"))
        _ = scope.stopIntercepting(host: "api.test")
        #expect(!scope.shouldIntercept(host: "api.test"))
        _ = scope.intercept(host: "api.test")
        #expect(scope.shouldIntercept(host: "api.test"), "re-adding must not lose to a leftover exclude")
    }
}
