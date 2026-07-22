import XCTest
@testable import ProxyCore
import SharedModels

/// Regression: the forwarder decompresses the upstream body, so forwarding the
/// origin's Content-Encoding/Content-Length makes the client re-decode plaintext
/// and fail with -1015 "cannot decode raw data". Those headers must be stripped.
final class ResponseHeaderSanitizeTests: XCTestCase {
    func test_stripsContentEncodingAndLength_caseInsensitive() {
        let input = [
            HeaderPair(name: "Content-Type", value: "text/html"),
            HeaderPair(name: "Content-Encoding", value: "br"),
            HeaderPair(name: "content-length", value: "559"),
            HeaderPair(name: "Server", value: "cloudflare"),
        ]
        let out = HTTPUtil.sanitizeDecodedResponseHeaders(input)
        let names = out.map { $0.name.lowercased() }
        XCTAssertFalse(names.contains("content-encoding"))
        XCTAssertFalse(names.contains("content-length"))
        XCTAssertTrue(names.contains("content-type"))
        XCTAssertTrue(names.contains("server"))
        XCTAssertEqual(out.count, 2)
    }

    func test_leavesOtherHeadersUntouched() {
        let input = [
            HeaderPair(name: "Content-Type", value: "application/json"),
            HeaderPair(name: "Cache-Control", value: "no-cache"),
        ]
        XCTAssertEqual(HTTPUtil.sanitizeDecodedResponseHeaders(input), input)
    }

    // Regression: a bodyless response (HEAD / 1xx / 204 / 304) must not be framed
    // chunked — a `0\r\n\r\n` after it corrupts a keep-alive connection.
    func test_responseHasNoBody() {
        XCTAssertTrue(HTTPUtil.responseHasNoBody(requestMethod: "HEAD", status: 200))
        XCTAssertTrue(HTTPUtil.responseHasNoBody(requestMethod: "head", status: 200))
        XCTAssertTrue(HTTPUtil.responseHasNoBody(requestMethod: "GET", status: 204))
        XCTAssertTrue(HTTPUtil.responseHasNoBody(requestMethod: "GET", status: 304))
        XCTAssertTrue(HTTPUtil.responseHasNoBody(requestMethod: "GET", status: 100))
        XCTAssertFalse(HTTPUtil.responseHasNoBody(requestMethod: "GET", status: 200))
        XCTAssertFalse(HTTPUtil.responseHasNoBody(requestMethod: "POST", status: 201))
    }
}
