import Testing
import Foundation
import LoomSharedModels
@testable import MCPServer

/// Unit contract for `FlowDiff` — the pure "observe" step. Exercises header
/// add/remove/change grouping, the LCS line diff, binary/oversized fallbacks,
/// and the `identical` flag, all without NIO or the MCP layer.
@Suite struct FlowDiffTests {
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

    @Test func identicalFlows_reportIdentical() {
        let a = flow(reqHeaders: [HeaderPair(name: "Accept", value: "json")], respBody: Data("hi".utf8))
        let b = flow(reqHeaders: [HeaderPair(name: "Accept", value: "json")], respBody: Data("hi".utf8))
        let diff = FlowDiff.diff(base: a, compared: b)
        #expect(diff["identical"] as? Bool == true)
        #expect(diff["request"] == nil)
        #expect(diff["response"] == nil)
    }

    @Test func methodAndStatus_scalarDiff() {
        let a = flow(method: "GET", status: 200)
        let b = flow(method: "POST", status: 500)
        let diff = FlowDiff.diff(base: a, compared: b)
        #expect(diff["identical"] as? Bool == false)
        let method = try? #require(diff["request"] as? [String: Any]).flatMap { $0["method"] as? [String: Any] }
        #expect(method?["base"] as? String == "GET")
        #expect(method?["compared"] as? String == "POST")
        let status = (diff["response"] as? [String: Any])?["status"] as? [String: Any]
        #expect(status?["base"] as? Int == 200)
        #expect(status?["compared"] as? Int == 500)
    }

    @Test func headerDiff_addRemoveChange_caseInsensitiveName() {
        let base = [
            HeaderPair(name: "Authorization", value: "old"),
            HeaderPair(name: "X-Gone", value: "1"),
        ]
        let compared = [
            HeaderPair(name: "authorization", value: "new"), // changed (case-insensitive match)
            HeaderPair(name: "X-New", value: "2"),            // added
        ]
        let diff = FlowDiff.headerDiff(base, compared)
        let added = try? #require(diff["added"] as? [[String: Any]])
        let removed = try? #require(diff["removed"] as? [[String: Any]])
        let changed = try? #require(diff["changed"] as? [[String: Any]])
        #expect(added?.first?["name"] as? String == "X-New")
        #expect(removed?.first?["name"] as? String == "X-Gone")
        #expect(changed?.first?["name"] as? String == "authorization")
        #expect(changed?.first?["base"] as? [String] == ["old"])
        #expect(changed?.first?["compared"] as? [String] == ["new"])
    }

    @Test func bodyDiff_lineLevel() {
        let base = Data("line1\nline2\nline3".utf8)
        let compared = Data("line1\nCHANGED\nline3".utf8)
        let diff = FlowDiff.bodyDiff(base, compared)
        #expect(diff["removedLines"] as? [String] == ["line2"])
        #expect(diff["addedLines"] as? [String] == ["CHANGED"])
        #expect(diff["baseBytes"] as? Int == base.count)
    }

    @Test func bodyDiff_binary_flagsBinaryWithoutLineDiff() {
        let base = Data([0xFF, 0xFE, 0x00])
        let compared = Data([0xFF, 0x01, 0x02])
        let diff = FlowDiff.bodyDiff(base, compared)
        #expect(diff["binary"] as? Bool == true)
        #expect(diff["addedLines"] == nil)
    }

    @Test func bodyDiff_identical_isEmpty() {
        #expect(FlowDiff.bodyDiff(Data("same".utf8), Data("same".utf8)).isEmpty)
        #expect(FlowDiff.bodyDiff(nil, nil).isEmpty)
    }

    @Test func lineDiff_lcsKeepsCommonRuns() {
        let (added, removed) = FlowDiff.lineDiff(["a", "b", "c"], ["a", "x", "c", "d"])
        #expect(removed == ["b"])
        #expect(added == ["x", "d"])
    }
}
