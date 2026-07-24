import SharedModels
import XCTest

@testable import AppFeature

// MARK: - Order-preserving JSON

final class JSONValueTests: XCTestCase {
    private func parse(_ s: String) -> JSONValue? { JSONValue.parse(Data(s.utf8)) }

    func test_object_preservesKeyOrder() {
        // Foundation's JSONSerialization reshuffles keys; a debugger must not.
        XCTAssertEqual(parse(#"{"b":1,"a":2}"#), .object([("b", .number("1")), ("a", .number("2"))]))
        XCTAssertNotEqual(parse(#"{"b":1,"a":2}"#), .object([("a", .number("2")), ("b", .number("1"))]))
    }

    func test_nestedContainers_boolNullNumberString() {
        let parsed = parse(#"{"s":"a\nb","arr":[true,null,3.5]}"#)
        XCTAssertEqual(parsed, .object([
            ("s", .string("a\nb")),
            ("arr", .array([.bool(true), .null, .number("3.5")])),
        ]))
    }

    func test_unicodeEscape() {
        // JSON text {"k":"Aé"} decodes to "Aé".
        let json = "{\"k\":\"\\u0041\\u00e9\"}"
        XCTAssertEqual(parse(json), .object([("k", .string("Aé"))]))
    }

    func test_malformed_returnsNil() {
        XCTAssertNil(parse(#"{"a":}"#))
        XCTAssertNil(parse("not json"))
        XCTAssertNil(parse(#"{"a":1"#)) // unterminated object
    }

    func test_prettyPrinted_roundTrips() {
        let original = parse(#"{"z":[1,2],"a":{"nested":"x"}}"#)
        XCTAssertNotNil(original)
        let reparsed = JSONValue.parse(Data(original!.prettyPrinted().utf8))
        XCTAssertEqual(reparsed, original) // reformatting never reorders keys
    }
}

// MARK: - Cookie parsing

final class CookieParsingTests: XCTestCase {
    func test_requestCookies_splitsPairs() {
        let cookies = CookieParsing.requestCookies([
            HeaderPair(name: "Cookie", value: "a=1; b=2"),
        ])
        XCTAssertEqual(cookies.map(\.name), ["a", "b"])
        XCTAssertEqual(cookies.map(\.value), ["1", "2"])
    }

    func test_requestCookies_caseInsensitiveHeaderAndDropsMalformed() {
        let cookies = CookieParsing.requestCookies([
            HeaderPair(name: "cookie", value: "ok=yes; bare; =leading"),
        ])
        XCTAssertEqual(cookies.map(\.name), ["ok"]) // "bare" (no =) and "=leading" dropped
    }

    func test_responseCookies_splitsValueFromAttributes() {
        let cookies = CookieParsing.responseCookies([
            HeaderPair(name: "Set-Cookie", value: "session=xyz; Path=/; HttpOnly"),
        ])
        XCTAssertEqual(cookies.first?.name, "session")
        XCTAssertEqual(cookies.first?.value, "xyz")
        XCTAssertEqual(cookies.first?.attributes, "Path=/ · HttpOnly")
    }
}

// MARK: - cURL reconstruction

final class CurlCommandTests: XCTestCase {
    func test_get_omitsMethodFlag_andCurlSetHeaders() {
        let flow = Fixtures.flow(
            method: "GET",
            url: "https://api.example.com/v1/home",
            requestHeaders: [
                HeaderPair(name: "Accept", value: "application/json"),
                HeaderPair(name: "Host", value: "api.example.com"),      // curl sets it
                HeaderPair(name: "Content-Length", value: "0"),          // curl sets it
            ]
        )
        let curl = Curl.command(flow)
        XCTAssertFalse(curl.contains("-X"), "GET should not carry an explicit method")
        XCTAssertTrue(curl.contains("'https://api.example.com/v1/home'"))
        XCTAssertTrue(curl.contains("-H 'Accept: application/json'"))
        XCTAssertFalse(curl.contains("Host:"), "curl sets Host itself")
        XCTAssertFalse(curl.contains("Content-Length:"), "curl sets Content-Length itself")
    }

    func test_post_addsMethodAndBody() {
        let flow = Fixtures.flow(
            method: "POST",
            url: "https://api.example.com/v1/login",
            requestBody: Data(#"{"u":"a"}"#.utf8),
            status: 200
        )
        let curl = Curl.command(flow)
        XCTAssertTrue(curl.contains("-X POST"))
        XCTAssertTrue(curl.contains(#"--data '{"u":"a"}'"#))
    }

    func test_singleQuotesInValuesAreEscaped() {
        let flow = Fixtures.flow(
            method: "GET",
            url: "https://api.example.com/it's",
            requestHeaders: []
        )
        let curl = Curl.command(flow)
        XCTAssertTrue(curl.contains(#"it'\''s"#), "single quotes must be POSIX-escaped")
    }
}

// MARK: - One-click rule templates

final class RuleFactoryTests: XCTestCase {
    func test_mockResponse_pinsCapturedResponse_stripsQuery() {
        let flow = Fixtures.flow(
            method: "GET",
            url: "https://api.example.com/v1/home?x=1",
            status: 201,
            responseBody: Data(#"{"pinned":true}"#.utf8)
        )
        let rule = RuleFactory.rule(from: flow, template: .mockResponse)
        XCTAssertEqual(rule?.match.urlPattern, "https://api.example.com/v1/home") // query stripped
        XCTAssertEqual(rule?.match.methods, ["GET"])
        guard case let .mock(mock) = rule?.actions.route else { return XCTFail("expected mock") }
        XCTAssertEqual(mock.statusCode, 201)
        XCTAssertEqual(mock.bodyText, #"{"pinned":true}"#)
    }

    func test_blockURL_blocksExactPrefix() {
        let flow = Fixtures.flow(url: "https://api.example.com/v1/home?x=1")
        let rule = RuleFactory.rule(from: flow, template: .blockURL)
        XCTAssertEqual(rule?.actions.route, .block)
        XCTAssertEqual(rule?.match.urlPattern, "https://api.example.com/v1/home")
        XCTAssertFalse(rule?.match.isRegex ?? true)
    }

    func test_blockHost_usesAnchoredRegex_notSubstringGlob() {
        let flow = Fixtures.flow(url: "https://api.example.com/v1/home")
        let rule = RuleFactory.rule(from: flow, template: .blockHost)
        XCTAssertEqual(rule?.actions.route, .block)
        XCTAssertTrue(rule?.match.isRegex ?? false)
        // Must match the host but not a look-alike suffix domain.
        XCTAssertTrue(rule!.match.matches(method: "GET", url: "https://api.example.com/x"))
        XCTAssertFalse(rule!.match.matches(method: "GET", url: "https://api.example.com.evil.io/x"))
    }

    func test_blockHost_nilHost_returnsNil() {
        let flow = Fixtures.flow(url: "garbage-not-a-url")
        XCTAssertNil(RuleFactory.rule(from: flow, template: .blockHost))
    }
}
