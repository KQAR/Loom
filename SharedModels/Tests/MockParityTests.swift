import XCTest
import Foundation
@testable import SharedModels

/// Covers the mock-model parity fields (exact match, host/query predicates,
/// binary response body) that let a host embedder map a richer mock model onto
/// `TrafficRule` without loss.
final class MockParityMatchTests: XCTestCase {
    func test_isExact_matchesOnlyWholeURL() {
        let match = RuleMatch(urlPattern: "https://api.example.test/v1/home", isExact: true)
        XCTAssertTrue(match.matches(method: "GET", url: "https://api.example.test/v1/home"))
        XCTAssertFalse(match.matches(method: "GET", url: "https://api.example.test/v1/home/extra"))
        XCTAssertFalse(match.matches(method: "GET", url: "https://api.example.test/v1/home?x=1"))
    }

    func test_default_isPrefix_unchanged() {
        let match = RuleMatch(urlPattern: "https://api.example.test/v1/home")
        XCTAssertTrue(match.matches(method: "GET", url: "https://api.example.test/v1/home?x=1"))
        XCTAssertTrue(match.matches(method: "GET", url: "https://api.example.test/v1/home/extra"))
    }

    func test_hostPattern_gate() {
        let match = RuleMatch(urlPattern: "*", hostPattern: "*.example.test")
        XCTAssertTrue(match.matches(method: "GET", url: "https://api.example.test/x"))
        XCTAssertFalse(match.matches(method: "GET", url: "https://api.other.test/x"))
    }

    func test_query_equalityAndPresence() {
        let equals = RuleMatch(urlPattern: "*", query: ["v": "2"])
        XCTAssertTrue(equals.matches(method: "GET", url: "https://a.test/x?v=2&z=1"))
        XCTAssertFalse(equals.matches(method: "GET", url: "https://a.test/x?v=3"))
        XCTAssertFalse(equals.matches(method: "GET", url: "https://a.test/x"))

        let presence = RuleMatch(urlPattern: "*", query: ["token": "*"])
        XCTAssertTrue(presence.matches(method: "GET", url: "https://a.test/x?token=anything"))
        XCTAssertFalse(presence.matches(method: "GET", url: "https://a.test/x?other=1"))
    }

    func test_query_isOrderIndependent() {
        let match = RuleMatch(urlPattern: "*", query: ["a": "1", "b": "2"])
        XCTAssertTrue(match.matches(method: "GET", url: "https://a.test/x?b=2&a=1"))
    }
}

final class MockResponseBodyTests: XCTestCase {
    func test_resolvedBody_prefersBase64_forBinary() {
        let bytes = Data([0x00, 0xFF, 0x10, 0x80])
        let mock = MockResponseAction(bodyBase64: bytes.base64EncodedString())
        XCTAssertEqual(mock.resolvedBody(), bytes)
    }

    func test_resolvedBody_fallsBackToText() {
        let mock = MockResponseAction(bodyText: "hello")
        XCTAssertEqual(mock.resolvedBody(), Data("hello".utf8))
    }

    func test_resolvedBody_base64WinsOverText() {
        let mock = MockResponseAction(bodyText: "ignored", bodyBase64: Data("bin".utf8).base64EncodedString())
        XCTAssertEqual(mock.resolvedBody(), Data("bin".utf8))
    }

    func test_resolvedBody_emptyWhenNothingSet() {
        XCTAssertEqual(MockResponseAction().resolvedBody(), Data())
    }

    func test_validation_rejectsBadBase64() {
        let rule = TrafficRule(
            name: "bad",
            match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mock(MockResponseAction(bodyBase64: "not base64!!")))
        )
        XCTAssertNotNil(rule.validationError())
    }
}

final class MockModelDecodeTests: XCTestCase {
    func test_ruleMatch_decodesLegacyJSON_withoutNewKeys() throws {
        let json = Data(#"{"urlPattern":"https://a.test/x","isRegex":false,"methods":["GET"]}"#.utf8)
        let match = try JSONDecoder().decode(RuleMatch.self, from: json)
        XCTAssertEqual(match.urlPattern, "https://a.test/x")
        XCTAssertFalse(match.isExact)
        XCTAssertNil(match.hostPattern)
        XCTAssertNil(match.query)
    }

    func test_mockResponse_decodesLegacyJSON_withoutBase64() throws {
        let json = Data(#"{"statusCode":200,"headers":[],"bodyText":"ok"}"#.utf8)
        let mock = try JSONDecoder().decode(MockResponseAction.self, from: json)
        XCTAssertEqual(mock.bodyText, "ok")
        XCTAssertNil(mock.bodyBase64)
    }

    func test_roundTrip_preservesNewFields() throws {
        let match = RuleMatch(urlPattern: "https://a.test/x", isExact: true, hostPattern: "*.test", query: ["v": "2"])
        let decoded = try JSONDecoder().decode(RuleMatch.self, from: JSONEncoder().encode(match))
        XCTAssertEqual(decoded, match)
    }
}
