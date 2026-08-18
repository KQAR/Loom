import Foundation
import Testing
@testable import AppFeature

/// Which parts of a request URL get a colour in the inspector header.
///
/// The two things worth pinning are both about *restraint*: punctuation and a
/// fragment must stay unspanned (they are not one of the four roles), and a
/// string that is not `scheme://…` must be left alone rather than guessed at.
@Suite struct URLHighlightTests {
    private func roles(_ url: String) -> [URLHighlight.Role] {
        URLHighlight.spans(in: url).map(\.role)
    }

    private func text(_ url: String, of span: URLHighlight.Span) -> String {
        String(url[span.range])
    }

    private func texts(_ url: String) -> [String] {
        URLHighlight.spans(in: url).map { text(url, of: $0) }
    }

    @Test func aFullURLSplitsIntoFourRoles() {
        let url = "https://api.example.com/v1/users?id=1"
        #expect(roles(url) == [.scheme, .host, .path, .query])
        #expect(texts(url) == ["https", "api.example.com", "/v1/users", "?id=1"])
    }

    @Test func theSchemeDelimiterIsUnspanned() {
        // `://` is punctuation, not a fifth role. A port colon *is* part of host
        // (`example.test:443`), so this checks the delimiter rather than every `:`.
        let url = "https://api.example.com/v1"
        let spanned = texts(url).joined()
        #expect(!spanned.contains("://"))
        #expect(texts(url) == ["https", "api.example.com", "/v1"])
    }

    @Test func aURLWithNoQueryOmitsThatRole() {
        let url = "https://api.example.com/v1/users"
        #expect(roles(url) == [.scheme, .host, .path])
        #expect(texts(url) == ["https", "api.example.com", "/v1/users"])
    }

    @Test func aURLWithNoPathOmitsThatRole() {
        // Loom records CONNECT as `https://host:port` with no path.
        let url = "https://example.test:443"
        #expect(roles(url) == [.scheme, .host])
        #expect(texts(url) == ["https", "example.test:443"])
    }

    @Test func aQueryWithNoPathIsStillAQuery() {
        let url = "https://h.test?q=1"
        #expect(roles(url) == [.scheme, .host, .query])
        #expect(texts(url) == ["https", "h.test", "?q=1"])
    }

    @Test func aFragmentIsNotPartOfTheQuery() {
        let url = "https://h.test/a/b?x=1#deep"
        #expect(roles(url) == [.scheme, .host, .path, .query])
        #expect(texts(url) == ["https", "h.test", "/a/b", "?x=1"])
    }

    @Test func userinfoIsNotTheHost() {
        let url = "https://alice:secret@api.example.com/v1"
        #expect(texts(url) == ["https", "api.example.com", "/v1"])
    }

    @Test func theLastAtEndsUserinfo() {
        let url = "https://a@b@c.com/x"
        #expect(texts(url) == ["https", "c.com", "/x"])
    }

    @Test func ipv6LiteralKeepsBracketsAndPort() {
        let url = "https://[::1]:8443/p"
        #expect(texts(url) == ["https", "[::1]:8443", "/p"])
    }

    @Test func percentEncodedPathIsLeftAsSent() {
        let url = "https://h.test/a%20b?q=1"
        #expect(texts(url) == ["https", "h.test", "/a%20b", "?q=1"])
    }

    @Test func aStringThatIsNotAURLIsLeftAlone() {
        #expect(roles("").isEmpty)
        #expect(roles("not a url at all").isEmpty)
        #expect(roles("/relative").isEmpty)
        #expect(roles("mailto:dev@example.com").isEmpty)
    }
}
