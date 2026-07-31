import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// Regression: the forwarder decompresses the upstream body, so forwarding the
/// origin's Content-Encoding/Content-Length makes the client re-decode plaintext
/// and fail with -1015 "cannot decode raw data". Those headers must be stripped —
/// but only when the response really was encoded, because an unencoded body
/// arrives byte-for-byte and its Content-Length is the truth.
@Suite struct ResponseHeaderSanitizeTests {
    @Test func stripsContentEncodingAndLength_caseInsensitive() {
        let input = [
            HeaderPair(name: "Content-Type", value: "text/html"),
            HeaderPair(name: "Content-Encoding", value: "gzip"),
            HeaderPair(name: "content-length", value: "559"),
            HeaderPair(name: "Server", value: "cloudflare"),
        ]
        let out = HTTPUtil.sanitizeDecodedResponseHeaders(input)
        let names = out.map { $0.name.lowercased() }
        #expect(!names.contains("content-encoding"))
        #expect(!names.contains("content-length"))
        #expect(names.contains("content-type"))
        #expect(names.contains("server"))
        #expect(out.count == 2)
    }

    @Test func leavesOtherHeadersUntouched() {
        let input = [
            HeaderPair(name: "Content-Type", value: "application/json"),
            HeaderPair(name: "Cache-Control", value: "no-cache"),
        ]
        #expect(HTTPUtil.sanitizeDecodedResponseHeaders(input) == input)
    }

    /// An unencoded response passes through untouched, so its Content-Length still
    /// describes the bytes. Stripping it anyway lost a header the origin really sent
    /// from the capture, and left the bodyless writer — which documents that it
    /// preserves the upstream length — with nothing to preserve, so `curl -I`
    /// through Loom reported no Content-Length at all.
    @Test func keepsContentLengthWhenNothingWasDecoded() {
        let input = [
            HeaderPair(name: "Content-Type", value: "application/json"),
            HeaderPair(name: "Content-Length", value: "42"),
        ]
        #expect(HTTPUtil.sanitizeDecodedResponseHeaders(input) == input)
    }

    /// `identity` and an empty value mean "not encoded" — the decompressor leaves
    /// those bodies alone, so the length still holds.
    @Test(arguments: ["identity", "IDENTITY", "", "   "])
    func aNonEncodingContentEncodingKeepsTheLength(value: String) {
        let input = [
            HeaderPair(name: "Content-Encoding", value: value),
            HeaderPair(name: "Content-Length", value: "42"),
        ]
        let out = HTTPUtil.sanitizeDecodedResponseHeaders(input)
        #expect(out.contains { $0.name.lowercased() == "content-length" },
                "nothing was decoded, so the length is still true")
    }

    /// A comma list still means the body was encoded — strip.
    @Test func stripsWhenEncodingIsAList() {
        let input = [
            HeaderPair(name: "Content-Encoding", value: "gzip, identity"),
            HeaderPair(name: "Content-Length", value: "42"),
        ]
        #expect(HTTPUtil.sanitizeDecodedResponseHeaders(input).isEmpty)
    }

    /// Regression: a bodyless response (HEAD / 1xx / 204 / 304) must not be framed
    /// chunked — a `0\r\n\r\n` after it corrupts a keep-alive connection.
    @Test(arguments: [
        (method: "HEAD", status: 200, noBody: true),
        (method: "head", status: 200, noBody: true), // case-insensitive
        (method: "GET", status: 204, noBody: true),
        (method: "GET", status: 304, noBody: true),
        (method: "GET", status: 100, noBody: true),
        (method: "GET", status: 200, noBody: false),
        (method: "POST", status: 201, noBody: false),
    ])
    func responseHasNoBody(method: String, status: Int, noBody: Bool) {
        #expect(HTTPUtil.responseHasNoBody(requestMethod: method, status: status) == noBody)
    }
}
