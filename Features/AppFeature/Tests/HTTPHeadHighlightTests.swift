import Foundation
import Testing
@testable import AppFeature

/// Which parts of a raw HTTP message get a colour.
///
/// The two things worth pinning are both about *restraint*: the body must never
/// be touched (it has its own highlighting when it is JSON, and tinting
/// arbitrary payload text invents meaning), and a line that isn't a start line
/// or a header must be left alone rather than guessed at.
@Suite struct HTTPHeadHighlightTests {
    private func roles(_ text: String) -> [HTTPHeadHighlight.Role] {
        HTTPHeadHighlight.spans(in: text).map(\.role)
    }

    private func text(_ text: String, of span: HTTPHeadHighlight.Span) -> String {
        String(text[span.range])
    }

    @Test func aRequestHeadIsMethodThenHeaderNames() {
        let raw = "GET https://a.test/v1?x=1\nHost: a.test\nAccept: */*\n\nbody"
        let spans = HTTPHeadHighlight.spans(in: raw)
        #expect(spans.map(\.role) == [.method("GET"), .headerName, .headerName])
        #expect(text(raw, of: spans[0]) == "GET")
        #expect(text(raw, of: spans[1]) == "Host")
        #expect(text(raw, of: spans[2]) == "Accept")
    }

    @Test func aResponseHeadIsTheStatusCodeThenHeaderNames() {
        let raw = "HTTP 404\nServer: nginx\n\n{}"
        let spans = HTTPHeadHighlight.spans(in: raw)
        #expect(spans.map(\.role) == [.status(404), .headerName])
        #expect(text(raw, of: spans[0]) == "404")
    }

    @Test func theBodyIsNeverTouched() {
        // A JSON body is full of `"key": value` lines, which look exactly like
        // headers to a scanner that doesn't stop at the blank line — and colouring
        // them would both be wrong and cost the whole payload.
        let raw = "HTTP 200\nContent-Type: application/json\n\n{\n  \"name\": \"x\",\n  \"id\": 1\n}"
        #expect(roles(raw) == [.status(200), .headerName])
    }

    @Test func aHeadWithNoBlankLineIsStillBounded() {
        // Malformed input — an imported HAR with no separator, a truncated capture.
        // The cap is what stops this walking a multi-megabyte body looking for
        // colons.
        let lines = (0 ..< (HTTPHeadHighlight.maxHeadLines * 2)).map { "H\($0): v" }
        let raw = "HTTP 200\n" + lines.joined(separator: "\n")
        #expect(roles(raw).count == HTTPHeadHighlight.maxHeadLines)
    }

    @Test func aLineThatIsNeitherIsLeftAlone() {
        #expect(roles("").isEmpty)
        #expect(roles("just some text\n\nbody").isEmpty)
        // A colon in the *first* line does not make it a header — line one is the
        // start line or nothing.
        #expect(roles("weird: line\nHost: a.test").count == 1)
        // A leading colon is not a header name; an empty name would highlight
        // nothing and shift the value's colour.
        #expect(roles("HTTP 200\n: novalue").count == 1)
    }

    @Test func onlyTheFirstColonEndsAName() {
        // `Date: Thu, 13 Aug 2026 06:14:33 GMT` has three more colons in its value.
        let raw = "HTTP 200\nDate: Thu, 13 Aug 2026 06:14:33 GMT"
        let spans = HTTPHeadHighlight.spans(in: raw)
        #expect(text(raw, of: spans[1]) == "Date")
    }

    @Test func aMethodMustLookLikeOne() {
        // The start line of a request Loom rebuilt is `METHOD url`; a lowercase
        // first token is not a method and gets no tint rather than a wrong one.
        #expect(roles("get https://a.test\nHost: a.test") == [.headerName])
        #expect(roles("PROPFIND https://a.test") == [.method("PROPFIND")])
    }

    @Test func aStatusLineNeedsANumber() {
        #expect(roles("HTTP nonsense\nHost: a.test") == [.headerName])
    }
}
