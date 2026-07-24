import Foundation
import LoomSharedModels
import Testing

@testable import AppFeature

// MARK: - Order-preserving JSON

@Suite struct JSONValueTests {
    private func parse(_ s: String) -> JSONValue? { JSONValue.parse(Data(s.utf8)) }

    @Test func object_preservesKeyOrder() {
        // Foundation's JSONSerialization reshuffles keys; a debugger must not.
        #expect(parse(#"{"b":1,"a":2}"#) == .object([("b", .number("1")), ("a", .number("2"))]))
        #expect(parse(#"{"b":1,"a":2}"#) != .object([("a", .number("2")), ("b", .number("1"))]))
    }

    @Test func nestedContainers_boolNullNumberString() {
        let parsed = parse(#"{"s":"a\nb","arr":[true,null,3.5]}"#)
        #expect(parsed == .object([
            ("s", .string("a\nb")),
            ("arr", .array([.bool(true), .null, .number("3.5")])),
        ]))
    }

    @Test func unicodeEscape() {
        // JSON text {"k":"Aé"} decodes to "Aé".
        let json = "{\"k\":\"\\u0041\\u00e9\"}"
        #expect(parse(json) == .object([("k", .string("Aé"))]))
    }

    @Test(arguments: [
        #"{"a":}"#,     // value missing
        "not json",
        #"{"a":1"#,      // unterminated object
    ])
    func malformed_returnsNil(input: String) {
        #expect(parse(input) == nil)
    }

    @Test func prettyPrinted_roundTrips() throws {
        let original = try #require(parse(#"{"z":[1,2],"a":{"nested":"x"}}"#))
        let reparsed = JSONValue.parse(Data(original.prettyPrinted().utf8))
        #expect(reparsed == original) // reformatting never reorders keys
    }
}

// MARK: - Cookie parsing

@Suite struct CookieParsingTests {
    @Test func requestCookies_splitsPairs() {
        let cookies = CookieParsing.requestCookies([
            HeaderPair(name: "Cookie", value: "a=1; b=2"),
        ])
        #expect(cookies.map(\.name) == ["a", "b"])
        #expect(cookies.map(\.value) == ["1", "2"])
    }

    @Test func requestCookies_caseInsensitiveHeaderAndDropsMalformed() {
        let cookies = CookieParsing.requestCookies([
            HeaderPair(name: "cookie", value: "ok=yes; bare; =leading"),
        ])
        #expect(cookies.map(\.name) == ["ok"]) // "bare" (no =) and "=leading" dropped
    }

    @Test func responseCookies_splitsValueFromAttributes() {
        let cookies = CookieParsing.responseCookies([
            HeaderPair(name: "Set-Cookie", value: "session=xyz; Path=/; HttpOnly"),
        ])
        #expect(cookies.first?.name == "session")
        #expect(cookies.first?.value == "xyz")
        #expect(cookies.first?.attributes == "Path=/ · HttpOnly")
    }
}

// MARK: - cURL reconstruction

@Suite struct CurlCommandTests {
    @Test func get_omitsMethodFlag_andCurlSetHeaders() {
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
        #expect(!curl.contains("-X"), "GET should not carry an explicit method")
        #expect(curl.contains("'https://api.example.com/v1/home'"))
        #expect(curl.contains("-H 'Accept: application/json'"))
        #expect(!curl.contains("Host:"), "curl sets Host itself")
        #expect(!curl.contains("Content-Length:"), "curl sets Content-Length itself")
    }

    @Test func post_addsMethodAndBody() {
        let flow = Fixtures.flow(
            method: "POST",
            url: "https://api.example.com/v1/login",
            requestBody: Data(#"{"u":"a"}"#.utf8),
            status: 200
        )
        let curl = Curl.command(flow)
        #expect(curl.contains("-X POST"))
        #expect(curl.contains(#"--data '{"u":"a"}'"#))
    }

    @Test func singleQuotesInValuesAreEscaped() {
        let flow = Fixtures.flow(
            method: "GET",
            url: "https://api.example.com/it's",
            requestHeaders: []
        )
        let curl = Curl.command(flow)
        #expect(curl.contains(#"it'\''s"#), "single quotes must be POSIX-escaped")
    }
}

// MARK: - One-click rule templates

@Suite struct RuleFactoryTests {
    @Test func mockResponse_pinsCapturedResponse_stripsQuery() throws {
        let flow = Fixtures.flow(
            method: "GET",
            url: "https://api.example.com/v1/home?x=1",
            status: 201,
            responseBody: Data(#"{"pinned":true}"#.utf8)
        )
        let rule = RuleFactory.rule(from: flow, template: .mockResponse)
        #expect(rule?.match.urlPattern == "https://api.example.com/v1/home") // query stripped
        #expect(rule?.match.methods == ["GET"])
        guard case let .mock(mock) = rule?.actions.route else {
            Issue.record("expected mock")
            return
        }
        #expect(mock.statusCode == 201)
        #expect(mock.bodyText == #"{"pinned":true}"#)
    }

    @Test func blockURL_blocksExactPrefix() {
        let flow = Fixtures.flow(url: "https://api.example.com/v1/home?x=1")
        let rule = RuleFactory.rule(from: flow, template: .blockURL)
        #expect(rule?.actions.route == .block)
        #expect(rule?.match.urlPattern == "https://api.example.com/v1/home")
        #expect(!(rule?.match.isRegex ?? true))
    }

    @Test func blockHost_usesAnchoredRegex_notSubstringGlob() throws {
        let flow = Fixtures.flow(url: "https://api.example.com/v1/home")
        let rule = try #require(RuleFactory.rule(from: flow, template: .blockHost))
        #expect(rule.actions.route == .block)
        #expect(rule.match.isRegex)
        // Must match the host but not a look-alike suffix domain.
        #expect(rule.match.matches(method: "GET", url: "https://api.example.com/x"))
        #expect(!rule.match.matches(method: "GET", url: "https://api.example.com.evil.io/x"))
    }

    @Test func blockHost_nilHost_returnsNil() {
        let flow = Fixtures.flow(url: "garbage-not-a-url")
        #expect(RuleFactory.rule(from: flow, template: .blockHost) == nil)
    }
}
