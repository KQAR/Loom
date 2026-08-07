import Testing
import Foundation
import LoomSharedModels
@testable import MCPServer

/// Unit contract for `FlowDiff` — the pure "observe" step. Exercises header
/// add/remove/change grouping, the LCS line diff, binary/oversized fallbacks,
/// and the `identical` flag, all without NIO or the MCP layer.
@MainActor
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

    /// A missing side is an explicit JSON `null`, not an absent key — "was there,
    /// now isn't" must not read as "unchanged". The DTO writes `encode(to:)` by hand
    /// for this; the synthesized one would omit it.
    @Test func absentScalarSide_isJSONNull() {
        let a = flow(status: 200)
        let b = flow(status: nil)
        let diff = FlowDiff.diff(base: a, compared: b)
        let present = (diff["response"] as? [String: Any])?["present"] as? [String: Any]
        #expect(present?["base"] as? Bool == true)
        #expect(present?["compared"] as? Bool == false)

        let headers = FlowDiff.headerDiff([], [HeaderPair(name: "X", value: "1")])
        #expect((headers["added"] as? [[String: Any]])?.first?["values"] as? [String] == ["1"])
        #expect(headers["removed"] == nil, "an empty group is an absent key, as before")
    }

    // MARK: - Capture caps

    @Test func truncatedBodies_matchingPrefixes_sayTheTailWasNotCompared() {
        let prefix = Data("prefix".utf8)
        let diff = FlowDiff.bodyDiff(prefix, prefix, baseWireBytes: 900, comparedWireBytes: 1_200)
        #expect(diff["tailNotCompared"] as? Bool == true)
        #expect(diff["captureTruncated"] as? Bool == true)
        #expect(diff["baseBytesOnWire"] as? Int == 900)
        #expect(diff["comparedBytesOnWire"] as? Int == 1_200)
        #expect(diff["addedLines"] == nil)
    }

    @Test func untruncatedBody_carriesNoCapKeys() {
        let diff = FlowDiff.bodyDiff(Data("a".utf8), Data("b".utf8))
        #expect(diff["captureTruncated"] == nil, "a flag that only ever means true is absent otherwise")
        #expect(diff["tailNotCompared"] == nil)
        #expect(diff["baseBytesOnWire"] == nil)
    }

    /// `identical` alone would overclaim: the bytes past the cap were never read.
    @Test func truncatedFlow_flagsTheWholeDiffAsPartial() {
        let capped = Flow(
            request: CapturedRequest(method: "GET", url: "https://a.test", headers: []),
            startedAt: Date(timeIntervalSince1970: 1),
            outcome: .completed(
                CapturedResponse(statusCode: 200, headers: [], body: Data("p".utf8), fullBodyBytes: 50_000),
                at: Date(timeIntervalSince1970: 2)
            )
        )
        let diff = FlowDiff.diff(base: capped, compared: capped)
        #expect(diff["captureTruncated"] as? Bool == true)
        #expect(diff["identical"] as? Bool == false)
    }

    @Test func minifiedBody_reportsWhichLimitItHit() {
        let wide = String(repeating: "x", count: FlowComparison.maxDiffLineBytes + 1)
        let diff = FlowDiff.bodyDiff(Data(wide.utf8), Data((wide + "y").utf8))
        #expect(diff["lineDiffSkipped"] as? String == "a single line exceeds \(FlowComparison.maxDiffLineBytes) bytes")
        #expect(diff["addedLines"] == nil, "the whole payload is what the limit exists to keep out")
        #expect(diff["baseLines"] as? Int == 1)
    }

    // MARK: - WebSocket

    @Test func webSocketFrameLogs_reportTheFirstDivergence() {
        func webSocket(_ payloads: [String]) -> Flow {
            var result = flow()
            result.webSocketMessages = payloads.map {
                WebSocketMessage(
                    direction: .serverToClient, kind: .text, payload: Data($0.utf8),
                    timestamp: Date(timeIntervalSince1970: 3)
                )
            }
            return result
        }
        let diff = FlowDiff.diff(base: webSocket(["a", "b"]), compared: webSocket(["a", "c"]))
        #expect(diff["identical"] as? Bool == false)
        #expect((diff["webSocket"] as? [String: Any])?["firstDifferingMessage"] as? Int == 1)
    }

    @Test func nonWebSocketFlows_carryNoWebSocketBlock() {
        #expect(FlowDiff.diff(base: flow(), compared: flow())["webSocket"] == nil)
    }
}
