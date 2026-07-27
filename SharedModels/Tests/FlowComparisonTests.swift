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
        guard case let .tooLarge(baseLines, comparedLines, limit) = body?.detail else {
            Issue.record("expected the oversized fallback, got \(String(describing: body?.detail))")
            return
        }
        #expect(baseLines == FlowComparison.maxDiffLines + 1)
        #expect(comparedLines == 1)
        #expect(limit == FlowComparison.maxDiffLines)
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
