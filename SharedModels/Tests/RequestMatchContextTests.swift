import Foundation
import Testing
@testable import LoomSharedModels

/// One request, prepared once for a whole list of rules.
///
/// The context exists because every rule in a list is matched against the *same*
/// method and URL, so `URLComponents` was parsing that URL once per rule carrying a
/// host/query predicate and the glob path was re-encoding it once per glob rule — on
/// the event loop, per exchange. The saving is only legitimate if a shared context
/// gives the same verdict as a per-call one, and if reusing it across rules can't
/// leak one rule's state into the next: these pin both.
@Suite struct RequestMatchContextTests {
    private let url = "https://API.Example.com/v1/orders?page=2&flag"

    @Test func theSharedContextAgreesWithThePerCallForm() {
        let matches = [
            RuleMatch(urlPattern: "https://api.example.com/v1/*", style: .glob),
            RuleMatch(urlPattern: "https://api.example.com/v2/*", style: .glob),
            RuleMatch(urlPattern: "*/orders*", style: .glob, methods: ["GET"]),
            RuleMatch(urlPattern: "*/orders*", style: .glob, methods: ["POST"]),
            RuleMatch(urlPattern: "*", style: .glob, hostPattern: "*.example.com"),
            RuleMatch(urlPattern: "*", style: .glob, hostPattern: "*.other.com"),
            RuleMatch(urlPattern: "*", style: .glob, query: ["page": .equals("2")]),
            RuleMatch(urlPattern: "*", style: .glob, query: ["page": .equals("3")]),
            RuleMatch(urlPattern: "*", style: .glob, query: ["flag": .present]),
            RuleMatch(urlPattern: "*", style: .glob, query: ["nope": .present]),
            RuleMatch(urlPattern: "https://api.example.com", style: .prefix),
            RuleMatch(urlPattern: "https://API.Example.com/v1/orders?page=2&flag", style: .exact),
            RuleMatch(urlPattern: "/v1/orders", style: .regex),
            RuleMatch(urlPattern: "/v9/orders", style: .regex),
        ]
        // One context for the whole list, exactly as `RuleEngine.matchingRules` uses it.
        var shared = RequestMatchContext(method: "GET", url: url)
        for match in matches {
            let perCall = match.matches(method: "GET", url: url)
            #expect(
                match.matches(&shared) == perCall,
                "\(match.style) \"\(match.urlPattern)\": shared and per-call contexts disagree"
            )
        }
    }

    /// A context is reused across rules, so a lazily-derived value must be the URL's
    /// and nothing else's — re-reading it any number of times gives the same answer.
    @Test func lazyDerivationsAreStable() {
        var context = RequestMatchContext(method: "GET", url: url)
        #expect(context.host == "API.Example.com")
        #expect(context.host == "API.Example.com")
        #expect(context.queryItems == ["page": "2", "flag": ""])
        #expect(context.queryItems == ["page": "2", "flag": ""])
        #expect(context.asciiURL == Array(url.utf8))
    }

    /// A URL the byte path can't take: the context reports no ASCII bytes, and every
    /// pattern falls back to the string path rather than matching on folded bytes.
    @Test func aNonASCIIURLTakesTheStringPath() {
        let unicodeURL = "https://münchen.example/v1/straße"
        var context = RequestMatchContext(method: "GET", url: unicodeURL)
        #expect(context.asciiURL == nil)
        let match = RuleMatch(urlPattern: "*/STRASSE", style: .glob)
        #expect(match.matches(&context) == match.matches(method: "GET", url: unicodeURL))
        let hit = RuleMatch(urlPattern: "*münchen*", style: .glob)
        #expect(hit.matches(&context))
    }

    /// An origin-scoped rule fails closed on unattributed traffic, context or no
    /// context — the context carries the request, never the origin.
    @Test func originScopingIsUnaffectedByTheSharedContext() {
        var context = RequestMatchContext(method: "GET", url: url)
        let appScoped = RuleMatch(urlPattern: "*", style: .glob, sourceApp: "com.example.app")
        #expect(!appScoped.matches(&context, origin: nil))
        let origin = RequestOrigin(app: SourceApp(name: "App", bundleID: "com.example.app", pid: 1), device: nil)
        #expect(appScoped.matches(&context, origin: origin))
        // And the rule after it still sees an unpolluted context.
        let plain = RuleMatch(urlPattern: "*/orders*", style: .glob)
        #expect(plain.matches(&context, origin: nil))
    }
}
