import Testing
import Foundation
@testable import LoomSharedModels

/// Covers the mock-model parity fields (exact match, host/query predicates,
/// binary response body) that let a host embedder map a richer mock model onto
/// `TrafficRule` without loss.
@Suite struct MockParityMatchTests {
    @Test func isExact_matchesOnlyWholeURL() {
        let match = RuleMatch(urlPattern: "https://api.example.test/v1/home", isExact: true)
        #expect(match.matches(method: "GET", url: "https://api.example.test/v1/home"))
        #expect(!(match.matches(method: "GET", url: "https://api.example.test/v1/home/extra")))
        #expect(!(match.matches(method: "GET", url: "https://api.example.test/v1/home?x=1")))
    }

    @Test func default_isPrefix_unchanged() {
        let match = RuleMatch(urlPattern: "https://api.example.test/v1/home")
        #expect(match.matches(method: "GET", url: "https://api.example.test/v1/home?x=1"))
        #expect(match.matches(method: "GET", url: "https://api.example.test/v1/home/extra"))
    }

    @Test func hostPattern_gate() {
        let match = RuleMatch(urlPattern: "*", hostPattern: "*.example.test")
        #expect(match.matches(method: "GET", url: "https://api.example.test/x"))
        #expect(!(match.matches(method: "GET", url: "https://api.other.test/x")))
    }

    @Test func query_equalityAndPresence() {
        let equals = RuleMatch(urlPattern: "*", query: ["v": "2"])
        #expect(equals.matches(method: "GET", url: "https://a.test/x?v=2&z=1"))
        #expect(!(equals.matches(method: "GET", url: "https://a.test/x?v=3")))
        #expect(!(equals.matches(method: "GET", url: "https://a.test/x")))

        let presence = RuleMatch(urlPattern: "*", query: ["token": "*"])
        #expect(presence.matches(method: "GET", url: "https://a.test/x?token=anything"))
        #expect(!(presence.matches(method: "GET", url: "https://a.test/x?other=1")))
    }

    @Test func query_isOrderIndependent() {
        let match = RuleMatch(urlPattern: "*", query: ["a": "1", "b": "2"])
        #expect(match.matches(method: "GET", url: "https://a.test/x?b=2&a=1"))
    }
}

@Suite struct MockResponseBodyTests {
    @Test func resolvedBody_prefersBase64_forBinary() {
        let bytes = Data([0x00, 0xFF, 0x10, 0x80])
        let mock = MockResponseAction(bodyBase64: bytes.base64EncodedString())
        #expect(mock.resolvedBody() == bytes)
    }

    @Test func resolvedBody_fallsBackToText() {
        let mock = MockResponseAction(bodyText: "hello")
        #expect(mock.resolvedBody() == Data("hello".utf8))
    }

    @Test func resolvedBody_base64WinsOverText() {
        let mock = MockResponseAction(bodyText: "ignored", bodyBase64: Data("bin".utf8).base64EncodedString())
        #expect(mock.resolvedBody() == Data("bin".utf8))
    }

    @Test func resolvedBody_emptyWhenNothingSet() {
        #expect(MockResponseAction().resolvedBody() == Data())
    }

    @Test func validation_rejectsBadBase64() {
        let rule = TrafficRule(
            name: "bad",
            match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mock(MockResponseAction(bodyBase64: "not base64!!")))
        )
        #expect(rule.validationError() != nil)
    }
}

@Suite struct MockModelDecodeTests {
    @Test func ruleMatch_decodesLegacyJSON_withoutNewKeys() throws {
        let json = Data(#"{"urlPattern":"https://a.test/x","isRegex":false,"methods":["GET"]}"#.utf8)
        let match = try JSONDecoder().decode(RuleMatch.self, from: json)
        #expect(match.urlPattern == "https://a.test/x")
        #expect(!(match.isExact))
        #expect(match.hostPattern == nil)
        #expect(match.query == nil)
    }

    @Test func mockResponse_decodesLegacyJSON_withoutBase64() throws {
        let json = Data(#"{"statusCode":200,"headers":[],"bodyText":"ok"}"#.utf8)
        let mock = try JSONDecoder().decode(MockResponseAction.self, from: json)
        #expect(mock.bodyText == "ok")
        #expect(mock.bodyBase64 == nil)
    }

    @Test func roundTrip_preservesNewFields() throws {
        let match = RuleMatch(urlPattern: "https://a.test/x", isExact: true, hostPattern: "*.test", query: ["v": "2"])
        let decoded = try JSONDecoder().decode(RuleMatch.self, from: JSONEncoder().encode(match))
        #expect(decoded == match)
    }
}
