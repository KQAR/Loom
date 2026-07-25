import Testing
import Foundation
import LoomSharedModels

/// `URLHost` exists to make `Flow.host` cheap, and it is only worth having if it is
/// **indistinguishable** from what it replaced. So the contract is stated as parity
/// with `URLComponents(string:)?.host` over every URL shape that can reach a flow —
/// captured absolute-form URIs, MITM-built `https://host:port` URLs, CONNECT
/// authorities, WebSocket schemes, and whatever an agent passes to `replay_flow`.
///
/// The shapes it deliberately hands back to Foundation (percent-escapes, punycode,
/// malformed authorities) are listed explicitly, because that delegation *is* the
/// design — not a gap in it.
@Suite struct URLHostTests {
    /// Every case is asserted against the reference implementation rather than a
    /// hardcoded string, so this can't drift from Foundation's behaviour.
    private func expectParity(_ string: String, _ comment: Comment? = nil) {
        let reference = URLComponents(string: string)?.host
        #expect(
            URLHost.host(ofURLString: string) == reference,
            comment ?? "host(ofURLString:) must match URLComponents for \(string.debugDescription)"
        )
        // `hostMatches` is the allocation-free form of `host(...) == host`; it must
        // agree with it on every shape, or a filtered table would disagree with the
        // sidebar count beside it.
        if let reference {
            #expect(URLHost.hostMatches(urlString: string, host: reference))
        }
        #expect(
            !URLHost.hostMatches(urlString: string, host: "definitely-not-the-host.invalid"),
            "must not match an unrelated host for \(string.debugDescription)"
        )
    }

    @Test func ordinaryURLs() {
        for string in [
            "https://api.example.com/v1/home",
            "http://example.com",
            "https://example.com/",
            "https://api.example.com:8443/p",
            "https://api.example.com?q=1",
            "https://api.example.com#frag",
            "https://api.example.com/v1?url=https://other.com/x",
            "http://127.0.0.1:9090/x",
            "ws://api.example.com/socket",
            "wss://api.example.com:443/socket",
            "https://host.with.trailing.dot./x",
            "https://api_under.example.com/p",
            "https://api.example.com:/x",
            "https://api.example.com:99999/p",
        ] { expectParity(string) }
    }

    /// Case is preserved, not normalized — the sidebar groups on this string.
    @Test func caseIsPreserved() {
        expectParity("HTTPS://API.Example.com/x")
        #expect(URLHost.host(ofURLString: "https://EXAMPLE.com/x") == "EXAMPLE.com")
    }

    @Test func userinfoIsStripped_lastAtWins() {
        expectParity("https://user:pass@api.example.com:8443/p?q=1")
        expectParity("https://a@b@c.com/x")
        #expect(URLHost.host(ofURLString: "https://a@b@c.com/x") == "c.com")
    }

    /// The colons inside an IPv6 literal are not a port separator, and the brackets
    /// stay in the host — both easy to get wrong.
    @Test func ipv6Literals() {
        for string in [
            "https://[::1]:8443/p",
            "https://[fe80::1]/p",
            "http://[::ffff:127.0.0.1]:80/x",
            "https://user@[::1]:8443/p",
        ] { expectParity(string) }
        #expect(URLHost.host(ofURLString: "https://[::1]:8443/p") == "[::1]")
    }

    @Test func emptyAndMissingAuthority() {
        expectParity("https://")          // → ""
        expectParity("https:///path-only") // → ""
        expectParity("")                   // → nil
        expectParity("/relative/path")     // → nil
        expectParity("example.com:443")    // → nil (no scheme, so no authority)
        expectParity("not a url at all")
        expectParity("://missing-scheme/x")
    }

    /// CONNECT tunnels are recorded as `https://host:port` (`ProxyHandler`), and the
    /// MITM path builds the same shape from the CONNECT authority.
    @Test func connectAuthorityShape() {
        expectParity("https://api.example.com:443")
        #expect(URLHost.host(ofURLString: "https://api.example.com:443") == "api.example.com")
    }

    // MARK: Shapes deliberately delegated to Foundation

    /// Percent-escapes are decoded — a hand-rolled parser would return the raw form.
    @Test func percentEncodedHost_matchesFoundationsDecoding() {
        expectParity("https://exa%6dple.com/x")
        #expect(URLHost.host(ofURLString: "https://exa%6dple.com/x") == "example.com")
    }

    /// Punycode is decoded to Unicode; the fast path detects `xn--` and defers.
    @Test func punycodeHost_isDecoded() {
        expectParity("https://xn--fsq.com/p")
        #expect(URLHost.host(ofURLString: "https://xn--fsq.com/p") == "例.com")
        expectParity("https://XN--FSQ.com/p") // case-insensitive detection
        expectParity("https://sub.xn--fsq.com/p")
        expectParity("https://foo.xn--fsq.bar.com/p")
        expectParity("https://xn--.com/p")
        // `xn--` only means punycode at a *label start*, which is why the check is
        // boundary-aware: this host is ordinary and must take the fast path.
        expectParity("https://axn--fsq.com/p")
        #expect(URLHost.host(ofURLString: "https://axn--fsq.com/p") == "axn--fsq.com")
    }

    @Test func unicodeHost_isPassedThrough() {
        expectParity("https://例.com/x")
    }

    /// A malformed authority makes `URLComponents` reject the whole URL (nil), which
    /// the fast path must reproduce rather than salvaging a host from it.
    @Test func malformedAuthority_isNil() {
        expectParity("https://api.example.com\\backslash")
        #expect(URLHost.host(ofURLString: "https://api.example.com\\backslash") == nil)
        expectParity("https://api example.com/x")
        expectParity("https://[::1/x")   // unterminated literal
        expectParity("https://[::1]x/y") // junk after the literal
    }

    @Test func unusualButValidSchemes() {
        expectParity("h2c://api.example.com/x")
        expectParity("my-scheme+v2://api.example.com/x")
        expectParity("1nvalid://api.example.com/x") // scheme can't start with a digit
    }

    /// Sub-delims are legal in a reg-name; whatever Foundation does with them, we
    /// must do too (the fast path declines and delegates).
    @Test func subDelimitersInAuthority() {
        for string in [
            "https://ho!st.example.com/x",
            "https://ho,st.example.com/x",
            "https://ho;st.example.com/x",
            "https://ho=st.example.com/x",
            "https://ho&st.example.com/x",
        ] { expectParity(string) }
    }

    /// A sweep over generated combinations — the cheapest way to be confident the
    /// two implementations agree beyond the cases someone thought to list.
    @Test func generatedCombinations_allAgree() {
        let schemes = ["http", "https", "ws", "wss", "HTTPS"]
        let userinfos = ["", "user@", "user:pass@", "a@b@"]
        let hosts = ["example.com", "api.example.com", "127.0.0.1", "[::1]", "localhost", "x-y_z.example.com", ""]
        let ports = ["", ":80", ":8443", ":"]
        let paths = ["", "/", "/v1/home", "/v1?q=1", "#frag", "?q=1", "/a%20b"]

        for scheme in schemes {
            for userinfo in userinfos {
                for host in hosts {
                    for port in ports {
                        for path in paths {
                            expectParity("\(scheme)://\(userinfo)\(host)\(port)\(path)")
                        }
                    }
                }
            }
        }
    }

    /// A URL with no host must not match the empty string via `hostMatches` —
    /// otherwise "filter by host" would sweep up every unparseable URL.
    @Test func noHost_doesNotMatchEmptyString() {
        #expect(URLHost.host(ofURLString: "/relative") == nil)
        #expect(!URLHost.hostMatches(urlString: "/relative", host: ""))
        // …whereas an genuinely empty authority does report "".
        #expect(URLHost.host(ofURLString: "https://") == "")
        #expect(URLHost.hostMatches(urlString: "https://", host: ""))
    }

    @Test func flowHost_usesIt() {
        let flow = Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "https://user@api.example.com:8443/v1?q=1", headers: []),
            startedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(flow.host == "api.example.com")
    }
}
