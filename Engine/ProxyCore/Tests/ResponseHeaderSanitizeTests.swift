import Testing
@testable import ProxyCore
import SharedModels

/// Regression: the forwarder decompresses the upstream body, so forwarding the
/// origin's Content-Encoding/Content-Length makes the client re-decode plaintext
/// and fail with -1015 "cannot decode raw data". Those headers must be stripped.
@Suite struct ResponseHeaderSanitizeTests {
    @Test func stripsContentEncodingAndLength_caseInsensitive() {
        let input = [
            HeaderPair(name: "Content-Type", value: "text/html"),
            HeaderPair(name: "Content-Encoding", value: "br"),
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
