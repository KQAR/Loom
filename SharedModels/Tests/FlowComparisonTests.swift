import Foundation
import LoomSharedModels
import Testing

/// `FlowComparison` is the single definition of "what changed between two flows",
/// rendered as JSON by the `diff_flows` tool and as rows by the Inspector's diff
/// pane. These tests pin the semantics; `FlowDiffTests` (MCPServerTests) pins the
/// JSON shape on top of them.
@Suite struct FlowComparisonTests {
    private func flow(
        method: String = "GET",
        url: String = "https://api.example.com/x",
        requestHeaders: [HeaderPair] = [],
        requestBody: Data? = nil,
        status: Int? = 200,
        responseHeaders: [HeaderPair] = [],
        responseBody: Data? = nil,
        error: String? = nil
    ) -> Flow {
        let outcome: FlowOutcome
        if let error {
            outcome = .failed(FlowError(error), at: Date(timeIntervalSince1970: 2), partialResponse: nil)
        } else if let status {
            outcome = .completed(
                CapturedResponse(statusCode: status, headers: responseHeaders, body: responseBody),
                at: Date(timeIntervalSince1970: 2)
            )
        } else {
            outcome = .pending
        }
        return Flow(
            id: UUID(),
            request: CapturedRequest(method: method, url: url, headers: requestHeaders, body: requestBody),
            startedAt: Date(timeIntervalSince1970: 1),
            outcome: outcome
        )
    }

    @Test func identicalFlows() {
        let comparison = FlowComparison.compare(
            base: flow(requestHeaders: [HeaderPair(name: "Accept", value: "json")], responseBody: Data("hi".utf8)),
            compared: flow(requestHeaders: [HeaderPair(name: "Accept", value: "json")], responseBody: Data("hi".utf8))
        )
        #expect(comparison.isIdentical)
        #expect(comparison.request.isEmpty)
        #expect(comparison.response.isEmpty)
    }

    @Test func scalarChanges() {
        let comparison = FlowComparison.compare(
            base: flow(method: "GET", status: 200),
            compared: flow(method: "POST", status: 500)
        )
        #expect(!comparison.isIdentical)
        #expect(comparison.request.method == .init(base: "GET", compared: "POST"))
        #expect(comparison.response.status == .init(base: 200, compared: 500))
    }

    @Test func headers_addedRemovedChanged_caseInsensitiveByName() {
        let changes = FlowComparison.compareHeaders(
            [HeaderPair(name: "Authorization", value: "old"), HeaderPair(name: "X-Gone", value: "1")],
            [HeaderPair(name: "authorization", value: "new"), HeaderPair(name: "X-New", value: "2")]
        )
        #expect(changes.count == 3)
        let byName = Dictionary(uniqueKeysWithValues: changes.map { ($0.name.lowercased(), $0) })
        #expect(byName["authorization"]?.base == ["old"])
        #expect(byName["authorization"]?.compared == ["new"])
        #expect(byName["x-gone"]?.isRemoval == true)
        #expect(byName["x-new"]?.isAddition == true)
    }

    /// A repeated header is a list, so a dropped duplicate is a change rather than
    /// collapsing into "unchanged".
    @Test func repeatedHeader_keepsEveryValue() {
        let changes = FlowComparison.compareHeaders(
            [HeaderPair(name: "Set-Cookie", value: "a"), HeaderPair(name: "Set-Cookie", value: "b")],
            [HeaderPair(name: "Set-Cookie", value: "a")]
        )
        #expect(changes.count == 1)
        #expect(changes.first?.base == ["a", "b"])
        #expect(changes.first?.compared == ["a"])
    }

    @Test func identicalBodies_areNotAChange() {
        #expect(FlowComparison.compareBodies(Data("same".utf8), Data("same".utf8)) == nil)
        #expect(FlowComparison.compareBodies(nil, nil) == nil)
        #expect(FlowComparison.compareBodies(nil, Data()) == nil, "absent and empty are the same bytes")
    }

    @Test func textBodies_lineDiff() {
        let body = FlowComparison.compareBodies(Data("a\nb\nc".utf8), Data("a\nx\nc".utf8))
        #expect(body?.baseBytes == 5)
        #expect(body?.detail == .lines(added: ["x"], removed: ["b"]))
    }

    @Test func nonUTF8Body_reportsSizesOnly() {
        let binary = Data([0xFF, 0xFE, 0x00])
        let body = FlowComparison.compareBodies(Data("text".utf8), binary)
        #expect(body?.detail == .binary)
        #expect(body?.comparedBytes == 3)
    }

    @Test func oversizedBody_skipsTheLineDiff() {
        let big = (0 ... FlowComparison.maxDiffLines).map(String.init).joined(separator: "\n")
        let body = FlowComparison.compareBodies(Data(big.utf8), Data("one line".utf8))
        guard case let .tooLarge(baseLines, comparedLines, reason) = body?.detail else {
            Issue.record("expected the oversized fallback, got \(String(describing: body?.detail))")
            return
        }
        #expect(baseLines == FlowComparison.maxDiffLines + 1)
        #expect(comparedLines == 1)
        #expect(reason == .tooManyLines(limit: FlowComparison.maxDiffLines))
    }

    /// The case the line cap alone never caught: minified JSON is **one** line, so
    /// it passes `maxDiffLines` and its "line diff" is the whole payload twice.
    @Test func minifiedBody_isOneLineAndStillNotLineDiffed() {
        let minified = #"{"items":["# + (0 ..< 2000).map { "\"item\($0)\"" }.joined(separator: ",") + "]}"
        #expect(minified.split(separator: "\n").count == 1, "the point: one line")
        #expect(minified.utf8.count < FlowComparison.maxDiffBytes, "and under the byte ceiling")
        let body = FlowComparison.compareBodies(Data(minified.utf8), Data(minified.dropLast().utf8))
        guard case let .tooLarge(_, _, reason) = body?.detail else {
            Issue.record("expected the wide-line fallback, got \(String(describing: body?.detail))")
            return
        }
        #expect(reason == .lineTooLong(limit: FlowComparison.maxDiffLineBytes))
    }

    @Test func hugeBody_skipsTheLineDiffOnBytesBeforeSplitting() {
        let huge = String(repeating: "line\n", count: FlowComparison.maxDiffBytes / 5 + 10)
        let body = FlowComparison.compareBodies(Data(huge.utf8), Data("x".utf8))
        guard case let .tooLarge(baseLines, comparedLines, reason) = body?.detail else {
            Issue.record("expected the byte-ceiling fallback, got \(String(describing: body?.detail))")
            return
        }
        #expect(reason == .tooManyBytes(limit: FlowComparison.maxDiffBytes))
        // Counted without splitting; a trailing newline still opens a last line.
        #expect(baseLines == FlowComparison.maxDiffBytes / 5 + 11)
        #expect(comparedLines == 1)
    }

    // MARK: - Capture caps

    /// The silent-wrong-answer case: two bodies capped at the same byte count have
    /// identical prefixes whatever their tails did, and the diff used to call that
    /// "no difference".
    @Test func truncatedBodies_withMatchingPrefixes_areNotReportedIdentical() {
        let prefix = Data("the first kilobyte".utf8)
        let body = FlowComparison.compareBodies(
            prefix, prefix, baseWireBytes: 5_000, comparedWireBytes: 9_000
        )
        #expect(body != nil, "matching prefixes of capped bodies are not a known match")
        #expect(body?.detail == .tailNotCaptured)
        #expect(body?.isTruncated == true)
        #expect(body?.baseWireBytes == 5_000)
        #expect(body?.comparedWireBytes == 9_000)
    }

    @Test func truncatedBody_lineDiffIsFlaggedAsCoveringThePrefixOnly() {
        let body = FlowComparison.compareBodies(
            Data("a\nb".utf8), Data("a\nc".utf8), comparedWireBytes: 4_000
        )
        #expect(body?.detail == .lines(added: ["c"], removed: ["b"]))
        #expect(body?.isTruncated == true)
        #expect(body?.baseWireBytes == nil, "only the capped side carries a wire size")
    }

    @Test func truncatedFlow_reportsPartialEvenWhenNothingDiffers() {
        let capped = Flow(
            request: CapturedRequest(method: "GET", url: "https://a.test", headers: []),
            startedAt: Date(timeIntervalSince1970: 1),
            outcome: .completed(
                CapturedResponse(
                    statusCode: 200, headers: [], body: Data("prefix".utf8), fullBodyBytes: 100_000
                ),
                at: Date(timeIntervalSince1970: 2)
            )
        )
        let comparison = FlowComparison.compare(base: capped, compared: capped)
        #expect(!comparison.isIdentical, "the tails were never compared")
        #expect(comparison.isPartial)
    }

    // MARK: - WebSocket

    private func webSocketFlow(_ payloads: [String], dropped: Int? = nil) -> Flow {
        var result = flow()
        result.webSocketMessages = payloads.enumerated().map { index, text in
            WebSocketMessage(
                direction: index.isMultiple(of: 2) ? .clientToServer : .serverToClient,
                kind: .text,
                payload: Data(text.utf8),
                timestamp: Date(timeIntervalSince1970: 3)
            )
        }
        result.webSocketDroppedMessages = dropped
        return result
    }

    /// Two WebSocket flows sharing only the HTTP upgrade used to compare
    /// "identical", and the Inspector said so in as many words.
    @Test func webSocketFrames_differingContent_isNotIdentical() {
        let comparison = FlowComparison.compare(
            base: webSocketFlow(["hello", "world"]),
            compared: webSocketFlow(["hello", "OTHER"])
        )
        #expect(!comparison.isIdentical)
        #expect(comparison.webSocket.messageCount == nil, "same count")
        #expect(comparison.webSocket.firstDifferingMessage == 1)
    }

    /// `id` and `timestamp` differ between any two captures of the same
    /// conversation, so comparing on them would make every pair differ at frame 0.
    @Test func webSocketFrames_sameContentDifferentIdsAndTimestamps_areIdentical() {
        var other = webSocketFlow(["hello", "world"])
        other.webSocketMessages = other.webSocketMessages?.map {
            WebSocketMessage(
                direction: $0.direction, kind: $0.kind, payload: $0.payload,
                timestamp: Date(timeIntervalSince1970: 999)
            )
        }
        let comparison = FlowComparison.compare(base: webSocketFlow(["hello", "world"]), compared: other)
        #expect(comparison.isIdentical)
        #expect(comparison.webSocket.isEmpty)
    }

    @Test func webSocket_presenceAndDroppedFrames() {
        let one = FlowComparison.compare(base: flow(), compared: webSocketFlow(["hi"]))
        #expect(one.webSocket.presence == .init(base: false, compared: true))
        #expect(one.webSocket.messageCount == nil, "presence is the difference")

        let two = FlowComparison.compare(
            base: webSocketFlow(["hi"], dropped: nil),
            compared: webSocketFlow(["hi"], dropped: 4)
        )
        #expect(two.webSocket.droppedMessages == .init(base: nil, compared: 4))
        #expect(!two.isIdentical)
    }

    @Test func nonWebSocketFlows_reportNothing() {
        #expect(FlowComparison.compare(base: flow(), compared: flow()).webSocket.isEmpty)
    }

    /// "One side never answered" is the difference; header/body diffs against a
    /// missing response would be noise.
    @Test func missingResponse_reportsPresenceOnly() {
        let comparison = FlowComparison.compare(base: flow(status: nil), compared: flow(status: 200))
        #expect(comparison.response.presence == .init(base: false, compared: true))
        #expect(comparison.response.status == nil)
        #expect(!comparison.isIdentical)
    }

    @Test func transportError_isItsOwnChange() {
        let comparison = FlowComparison.compare(
            base: flow(status: nil, error: "connection refused"),
            compared: flow(status: 200)
        )
        #expect(comparison.error?.base == "connection refused")
        #expect(comparison.error?.compared == nil)
    }

    @Test func lineDiff_keepsCommonSubsequence() {
        let (added, removed) = FlowComparison.lineDiff(["a", "b", "c"], ["a", "x", "c", "d"])
        #expect(added == ["x", "d"])
        #expect(removed == ["b"])
    }
}
