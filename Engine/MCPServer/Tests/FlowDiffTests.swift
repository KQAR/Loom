import XCTest
import SharedModels
@testable import MCPServer

/// Unit contract for `FlowDiff` — the pure "observe" step. Exercises header
/// add/remove/change grouping, the LCS line diff, binary/oversized fallbacks,
/// and the `identical` flag, all without NIO or the MCP layer.
final class FlowDiffTests: XCTestCase {
    private func flow(
        method: String = "GET",
        url: String = "https://api.example.com/x",
        reqHeaders: [HeaderPair] = [],
        reqBody: Data? = nil,
        status: Int? = 200,
        respHeaders: [HeaderPair] = [],
        respBody: Data? = nil,
        replayedFrom: UUID? = nil
    ) -> Flow {
        let outcome: FlowOutcome = status.map {
            .completed(CapturedResponse(statusCode: $0, headers: respHeaders, body: respBody), at: Date(timeIntervalSince1970: 2))
        } ?? .pending
        return Flow(
            id: UUID(),
            request: CapturedRequest(method: method, url: url, headers: reqHeaders, body: reqBody),
            startedAt: Date(timeIntervalSince1970: 1),
            outcome: outcome,
            replayedFrom: replayedFrom
        )
    }

    func test_identicalFlows_reportIdentical() {
        let a = flow(reqHeaders: [HeaderPair(name: "Accept", value: "json")], respBody: Data("hi".utf8))
        let b = flow(reqHeaders: [HeaderPair(name: "Accept", value: "json")], respBody: Data("hi".utf8))
        let diff = FlowDiff.diff(base: a, compared: b)
        XCTAssertEqual(diff["identical"] as? Bool, true)
        XCTAssertNil(diff["request"])
        XCTAssertNil(diff["response"])
    }

    func test_methodAndStatus_scalarDiff() {
        let a = flow(method: "GET", status: 200)
        let b = flow(method: "POST", status: 500)
        let diff = FlowDiff.diff(base: a, compared: b)
        XCTAssertEqual(diff["identical"] as? Bool, false)
        let method = try? XCTUnwrap(diff["request"] as? [String: Any]).flatMap { $0["method"] as? [String: Any] }
        XCTAssertEqual(method?["base"] as? String, "GET")
        XCTAssertEqual(method?["compared"] as? String, "POST")
        let status = (diff["response"] as? [String: Any])?["status"] as? [String: Any]
        XCTAssertEqual(status?["base"] as? Int, 200)
        XCTAssertEqual(status?["compared"] as? Int, 500)
    }

    func test_headerDiff_addRemoveChange_caseInsensitiveName() {
        let base = [
            HeaderPair(name: "Authorization", value: "old"),
            HeaderPair(name: "X-Gone", value: "1"),
        ]
        let compared = [
            HeaderPair(name: "authorization", value: "new"), // changed (case-insensitive match)
            HeaderPair(name: "X-New", value: "2"),            // added
        ]
        let diff = FlowDiff.headerDiff(base, compared)
        let added = try? XCTUnwrap(diff["added"] as? [[String: Any]])
        let removed = try? XCTUnwrap(diff["removed"] as? [[String: Any]])
        let changed = try? XCTUnwrap(diff["changed"] as? [[String: Any]])
        XCTAssertEqual(added?.first?["name"] as? String, "X-New")
        XCTAssertEqual(removed?.first?["name"] as? String, "X-Gone")
        XCTAssertEqual(changed?.first?["name"] as? String, "authorization")
        XCTAssertEqual(changed?.first?["base"] as? [String], ["old"])
        XCTAssertEqual(changed?.first?["compared"] as? [String], ["new"])
    }

    func test_bodyDiff_lineLevel() {
        let base = Data("line1\nline2\nline3".utf8)
        let compared = Data("line1\nCHANGED\nline3".utf8)
        let diff = FlowDiff.bodyDiff(base, compared)
        XCTAssertEqual(diff["removedLines"] as? [String], ["line2"])
        XCTAssertEqual(diff["addedLines"] as? [String], ["CHANGED"])
        XCTAssertEqual(diff["baseBytes"] as? Int, base.count)
    }

    func test_bodyDiff_binary_flagsBinaryWithoutLineDiff() {
        let base = Data([0xFF, 0xFE, 0x00])
        let compared = Data([0xFF, 0x01, 0x02])
        let diff = FlowDiff.bodyDiff(base, compared)
        XCTAssertEqual(diff["binary"] as? Bool, true)
        XCTAssertNil(diff["addedLines"])
    }

    func test_bodyDiff_identical_isEmpty() {
        XCTAssertTrue(FlowDiff.bodyDiff(Data("same".utf8), Data("same".utf8)).isEmpty)
        XCTAssertTrue(FlowDiff.bodyDiff(nil, nil).isEmpty)
    }

    func test_lineDiff_lcsKeepsCommonRuns() {
        let (added, removed) = FlowDiff.lineDiff(["a", "b", "c"], ["a", "x", "c", "d"])
        XCTAssertEqual(removed, ["b"])
        XCTAssertEqual(added, ["x", "d"])
    }
}
