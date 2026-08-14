import Testing
import Foundation
@testable import LoomSharedModels

/// Covers the mock-model parity fields (exact match, host/query predicates,
/// binary response body) that let a host embedder map a richer mock model onto
/// `TrafficRule` without loss.
@Suite struct MockParityMatchTests {
    @Test func isExact_matchesOnlyWholeURL() {
        let match = RuleMatch(urlPattern: "https://api.example.test/v1/home", style: .exact)
        #expect(match.matches(method: "GET", url: "https://api.example.test/v1/home"))
        #expect(!(match.matches(method: "GET", url: "https://api.example.test/v1/home/extra")))
        #expect(!(match.matches(method: "GET", url: "https://api.example.test/v1/home?x=1")))
    }

    @Test func default_isPrefix_unchanged() {
        let match = RuleMatch(urlPattern: "https://api.example.test/v1/home")
        #expect(match.matches(method: "GET", url: "https://api.example.test/v1/home?x=1"))
        #expect(match.matches(method: "GET", url: "https://api.example.test/v1/home/extra"))
    }

    @Test func urlGlob_coversWhatHostPatternUsedTo() {
        let match = RuleMatch(urlPattern: "https://*.example.test*")
        #expect(match.matches(method: "GET", url: "https://api.example.test/x"))
        #expect(!(match.matches(method: "GET", url: "https://api.other.test/x")))
    }

    @Test func query_equalityAndPresence() {
        let equals = RuleMatch(urlPattern: "*", query: ["v": .equals("2")])
        #expect(equals.matches(method: "GET", url: "https://a.test/x?v=2&z=1"))
        #expect(!(equals.matches(method: "GET", url: "https://a.test/x?v=3")))
        #expect(!(equals.matches(method: "GET", url: "https://a.test/x")))

        let presence = RuleMatch(urlPattern: "*", query: ["token": .present])
        #expect(presence.matches(method: "GET", url: "https://a.test/x?token=anything"))
        #expect(!(presence.matches(method: "GET", url: "https://a.test/x?other=1")))
    }

    @Test func query_isOrderIndependent() {
        let match = RuleMatch(urlPattern: "*", query: ["a": .equals("1"), "b": .equals("2")])
        #expect(match.matches(method: "GET", url: "https://a.test/x?b=2&a=1"))
    }
}

@Suite struct MockResponseBodyTests {
    @Test func resolvedBody_carriesBinaryBytesVerbatim() {
        let bytes = Data([0x00, 0xFF, 0x10, 0x80])
        let mock = MockResponseAction(body: .bytes(bytes))
        #expect(mock.resolvedBody() == bytes)
        #expect(mock.bodyBase64 == bytes.base64EncodedString())
        #expect(mock.bodyText == nil)
    }

    @Test func resolvedBody_encodesTextAsUTF8() {
        let mock = MockResponseAction(body: .text("hello"))
        #expect(mock.resolvedBody() == Data("hello".utf8))
        #expect(mock.bodyBase64 == nil)
    }

    /// Both wire keys can arrive in one object; the precedence lives at that
    /// boundary, and the model that comes out of it holds exactly one body.
    @Test func fromWire_base64WinsOverText() {
        let mock = MockResponseAction.fromWire(bodyText: "ignored", bodyBase64: Data("bin".utf8).base64EncodedString())
        #expect(mock.body == .bytes(Data("bin".utf8)))
        #expect(mock.resolvedBody() == Data("bin".utf8))
    }

    @Test func resolvedBody_emptyWhenNothingSet() {
        #expect(MockResponseAction().resolvedBody() == Data())
        #expect(MockResponseAction().body == nil)
    }
}

@Suite struct MockModelDecodeTests {
    @Test func ruleMatch_decodesLegacyJSON_withoutNewKeys() throws {
        let json = Data(#"{"urlPattern":"https://a.test/x","isRegex":false,"methods":["GET"]}"#.utf8)
        let match = try JSONDecoder().decode(RuleMatch.self, from: json)
        #expect(match.urlPattern == "https://a.test/x")
        #expect(!(match.isExact))
        #expect(match.expiredHostPattern == nil)
        #expect(match.query == nil)
    }

    @Test func mockResponse_decodesLegacyJSON_withoutBase64() throws {
        let json = Data(#"{"statusCode":200,"headers":[],"bodyText":"ok"}"#.utf8)
        let mock = try JSONDecoder().decode(MockResponseAction.self, from: json)
        #expect(mock.bodyText == "ok")
        #expect(mock.bodyBase64 == nil)
    }

    @Test func roundTrip_preservesNewFields() throws {
        let match = RuleMatch(urlPattern: "https://a.test/x", style: .exact, query: ["v": .equals("2")])
        let decoded = try JSONDecoder().decode(RuleMatch.self, from: JSONEncoder().encode(match))
        #expect(decoded == match)
    }
}

@Suite struct MatchStyleTests {
    /// The pair of booleans this replaced could not say "prefix, and the `*` is a
    /// literal" — glob was inferred from the character itself.
    @Test func aLiteralAsteriskCanBePrefixMatched() {
        let glob = RuleMatch(urlPattern: "https://a.test/*")
        #expect(glob.style == .glob)
        #expect(glob.matches(method: "GET", url: "https://a.test/anything"))

        let literal = RuleMatch(urlPattern: "https://a.test/*", style: .prefix)
        #expect(!literal.matches(method: "GET", url: "https://a.test/anything"))
        #expect(literal.matches(method: "GET", url: "https://a.test/*?x=1"))
    }

    @Test func inference_isGlobWhenThePatternSaysSo_elsePrefix() {
        #expect(MatchStyle.inferred(for: "https://a.test/x") == .prefix)
        #expect(MatchStyle.inferred(for: "https://a.test/*") == .glob)
        #expect(RuleMatch(urlPattern: "*").style == .glob)
    }

    /// A rules file written by a build that had `isRegex`/`isExact` still loads,
    /// with the precedence the old matcher applied (regex first) — including the
    /// combination that was illegal but representable.
    @Test func legacyBooleans_mapOntoAStyle() throws {
        func decode(_ json: String) throws -> RuleMatch {
            try JSONDecoder().decode(RuleMatch.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"urlPattern":"a","isRegex":true}"#).style == .regex)
        #expect(try decode(#"{"urlPattern":"a","isExact":true}"#).style == .exact)
        #expect(try decode(#"{"urlPattern":"a","isRegex":true,"isExact":true}"#).style == .regex)
        #expect(try decode(#"{"urlPattern":"a/*"}"#).style == .glob)
        #expect(try decode(#"{"urlPattern":"a"}"#).style == .prefix)
    }

    @Test func styleRoundTripsThroughJSON() throws {
        for style in MatchStyle.allCases {
            let match = RuleMatch(urlPattern: "https://a.test/x", style: style)
            let decoded = try JSONDecoder().decode(RuleMatch.self, from: JSONEncoder().encode(match))
            #expect(decoded.style == style)
        }
    }

    /// The wire/file shape is deliberately unchanged, so a rules file stays
    /// readable by any build: a mock still encodes `bodyText` / `bodyBase64`.
    @Test func mockBody_keepsItsFileShape() throws {
        let text = try JSONEncoder().encode(MockResponseAction(body: .text("hi")))
        let textJSON = try #require(try JSONSerialization.jsonObject(with: text) as? [String: Any])
        #expect(textJSON["bodyText"] as? String == "hi")
        #expect(textJSON["bodyBase64"] == nil)

        let binary = try JSONEncoder().encode(MockResponseAction(body: .bytes(Data("bin".utf8))))
        let binaryJSON = try #require(try JSONSerialization.jsonObject(with: binary) as? [String: Any])
        #expect(binaryJSON["bodyBase64"] as? String == Data("bin".utf8).base64EncodedString())
        #expect(binaryJSON["bodyText"] == nil)
    }
}

@Suite struct SubstitutionFieldTests {
    private func decode(_ json: String) throws -> SubstitutionRule {
        try JSONDecoder().decode(SubstitutionRule.self, from: Data(json.utf8))
    }

    /// Substitutions saved before headers could be targeted wrote `field` as a
    /// bare string, and they must keep meaning "every header value".
    @Test func aBareFieldStringDecodesAsUntargeted() throws {
        let sub = try decode(#"{"id":"6D3A4E0E-0000-4000-8000-000000000000","field":"header","match":"a","replacement":"b"}"#)
        #expect(sub.field == .header())
        #expect(sub.field.headerName == nil)
        #expect(sub.targets(header: "anything"))
    }

    @Test func aTargetedFieldRoundTrips() throws {
        let sub = SubstitutionRule(field: .header(name: "Authorization"), match: "a", replacement: "b")
        let decoded = try JSONDecoder().decode(SubstitutionRule.self, from: JSONEncoder().encode(sub))
        #expect(decoded.field == .header(name: "Authorization"))
        #expect(decoded.targets(header: "authorization"), "header names are case-insensitive")
        #expect(!decoded.targets(header: "X-Trace"))
    }

    /// The file shape only grows where it has to: an untargeted substitution still
    /// encodes `field` as a plain string, so an existing rules file round-trips
    /// byte-identically.
    @Test func anUntargetedFieldKeepsTheStringEncoding() throws {
        let data = try JSONEncoder().encode(SubstitutionRule(field: .body, match: "a", replacement: "b"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["field"] as? String == "body")

        let targeted = try JSONEncoder().encode(
            SubstitutionRule(field: .header(name: "X-Token"), match: "a", replacement: "b"))
        let targetedJSON = try #require(try JSONSerialization.jsonObject(with: targeted) as? [String: Any])
        #expect((targetedJSON["field"] as? [String: Any])?["headerName"] as? String == "X-Token")
    }

    @Test func anEmptyTargetIsNoTarget() {
        #expect(SubstitutionRule.Field(kind: .header, headerName: "") == .header())
        #expect(SubstitutionRule.Field(kind: .body, headerName: "X-Ignored") == .body)
    }

    @Test func onlyHeaderFieldsTargetHeaders() {
        #expect(!SubstitutionRule(field: .body, match: "a", replacement: "b").targets(header: "X"))
        #expect(!SubstitutionRule(field: .url, match: "a", replacement: "b").targets(header: "X"))
    }
}

@Suite struct QueryPredicateTests {
    /// The state the `*` sentinel swallowed: a parameter whose value really is `*`.
    @Test func aLiteralAsteriskValueCanBeRequired() {
        let anyValue = RuleMatch(urlPattern: "*", query: ["flag": .present])
        #expect(anyValue.matches(method: "GET", url: "https://a.test/x?flag=anything"))

        let literal = RuleMatch(urlPattern: "*", query: ["flag": .equals("*")])
        #expect(literal.matches(method: "GET", url: "https://a.test/x?flag=*"))
        #expect(!literal.matches(method: "GET", url: "https://a.test/x?flag=anything"))
    }

    @Test func legacySpelling_decodesAndKeepsItsFileShape() throws {
        let json = Data(#"{"urlPattern":"*","query":{"v":"2","token":"*"}}"#.utf8)
        let match = try JSONDecoder().decode(RuleMatch.self, from: json)
        #expect(match.query == ["v": .equals("2"), "token": .present])

        // Re-encoded in the same spelling — an existing rules file must not churn.
        let encoded = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(match)) as? [String: Any]
        #expect(encoded?["query"] as? [String: String] == ["v": "2", "token": "*"])
    }

    /// The format grows only for the predicate the short spelling cannot say.
    @Test func aLiteralAsteriskForcesTheExplicitEncoding() throws {
        let match = RuleMatch(urlPattern: "*", query: ["flag": .equals("*"), "v": .equals("2")])
        let data = try JSONEncoder().encode(match)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let query = try #require(json["query"] as? [String: [String: String]])
        #expect(query["flag"]?["equals"] == "*")
        #expect(query["v"]?["equals"] == "2")

        #expect(try JSONDecoder().decode(RuleMatch.self, from: data).query == match.query)
    }
}
