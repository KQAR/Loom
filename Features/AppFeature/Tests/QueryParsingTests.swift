import Foundation
import Testing
@testable import AppFeature

/// Splitting a URL's query into the pairs the inspector's Query tab shows.
///
/// Hand-rolled rather than `URLComponents.queryItems`, so the cases that matter
/// are the ones that type loses: a repeated key, a flag with no `=`, an
/// explicitly empty value, and a URL it would refuse outright — all of which a
/// debugging proxy sees constantly and must still display.
@Suite struct QueryParsingTests {
    private func parse(_ url: String) -> [URLQueryPair] {
        QueryParsing.items(inURL: url)
    }

    @Test func noQueryIsNoRows() {
        #expect(parse("https://a.test/v1").isEmpty)
        // A `?` with nothing after it is not a parameter.
        #expect(parse("https://a.test/v1?").isEmpty)
        #expect(parse("https://a.test/v1?&&").isEmpty)
    }

    @Test func pairsKeepTheirOrderAndTheirRepeats() {
        // `?id=1&id=2` is how half the web spells an array. Folding it to one
        // entry would hide the exact thing this tab is opened to check.
        let items = parse("https://a.test/v1?id=1&name=x&id=2")
        #expect(items.map(\.name) == ["id", "name", "id"])
        #expect(items.map(\.value) == ["1", "x", "2"])
    }

    @Test func aFlagIsNotAnEmptyValue() {
        // Plenty of servers treat `?debug` and `?debug=` differently, so the two
        // must not arrive here looking the same.
        let items = parse("https://a.test/v1?debug&verbose=")
        #expect(items[0].name == "debug")
        #expect(items[0].isFlag)
        #expect(items[1].name == "verbose")
        #expect(!items[1].isFlag)
        #expect(items[1].value.isEmpty)
    }

    @Test func valuesArePercentDecoded() {
        let items = parse("https://a.test/v1?q=hello%20world&path=%2Fa%2Fb")
        #expect(items[0].value == "hello world")
        #expect(items[1].value == "/a/b")
    }

    @Test func plusIsLeftAlone() {
        // Turning `+` into a space is a form-urlencoded *server-side reading*, not
        // a property of the URL — and a query string routinely carries base64
        // where every `+` is literal. Rewriting those would show something that
        // was never sent, in the one tool whose job is to say what was.
        #expect(parse("https://a.test/v1?token=ab+cd/ef=").first?.value == "ab+cd/ef=")
    }

    @Test func onlyTheFirstEqualsSplitsAPair() {
        // Base64 padding and nested query strings both put `=` inside a value.
        let items = parse("https://a.test/v1?next=%2Flogin%3Fa%3D1&sig=AAA==")
        #expect(items[0].value == "/login?a=1")
        #expect(items[1].value == "AAA==")
    }

    @Test func aFragmentIsNotPartOfTheQuery() {
        // It is also never sent to the server, which is worth not showing beside
        // things that were.
        let items = parse("https://a.test/v1?a=1#section=2")
        #expect(items.map(\.name) == ["a"])
        #expect(items[0].value == "1")
    }

    @Test func undecodableInputIsShownVerbatimRatherThanDropped() {
        // Malformed input is the normal case here, and it is exactly the parameter
        // someone is looking at *because* it looks wrong.
        let items = parse("https://a.test/v1?broken=%ZZ&fine=1")
        #expect(items.map(\.name) == ["broken", "fine"])
        #expect(items[0].value == "%ZZ")
    }

    @Test func rowsAreUniquelyIdentifiedEvenWhenIdentical() {
        // Two identical pairs are legal; positional identity is what keeps a
        // `ForEach` from reusing one row's view for the other.
        let items = parse("https://a.test/v1?a=1&a=1")
        #expect(items.count == 2)
        #expect(Set(items.map(\.id)).count == 2)
    }
}
