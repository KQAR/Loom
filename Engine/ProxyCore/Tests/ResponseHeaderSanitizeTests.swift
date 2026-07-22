import XCTest
@testable import ProxyCore
import SharedModels

/// Regression: URLSession decompresses the upstream body, so forwarding the
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
}
