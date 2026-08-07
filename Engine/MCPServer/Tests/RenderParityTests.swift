import Foundation
import LoomSharedModels
import Testing
@testable import MCPServer

/// Keeps every agent-facing render from drifting away from the model it renders.
///
/// ## The failure this exists to catch
///
/// A field added to `Flow` compiles everywhere. The model is `Codable`, so its own
/// serialization grows for free; the render does not, and nothing anywhere says
/// so — the agent simply never sees the new field, and the next person to look
/// concludes Loom doesn't record it. That already happened once to rules
/// (`RuleCodecParityTests`, and the `carried*` fields in `RuleDraft` are its
/// scar), and the same hole was open on every other model.
///
/// ## What it checks
///
/// A census, not an equality: for each model/render pair, every **stored property
/// of the model** must either appear as a stored property of the render, or be
/// listed in `accountedFor` with the reason. Renders are allowed extra fields —
/// shaping is their job (`ttfbMS` is computed, `captureTruncated` folds four model
/// fields into one answer) — so the check is one-directional, and the reasons are
/// where the shaping is written down.
///
/// Stale entries fail too: an `accountedFor` key that is no longer a model field
/// means the note outlived the thing it explained.
///
/// Stored properties come from `Mirror` rather than from encoding a value,
/// because a field is missing from an encoding exactly when it is nil — which is
/// the case a census must not be blind to — and because two of the models here
/// (`FlowStats.Bucket`, `GraphQLOperation`) aren't `Codable` at all.
@Suite struct RenderParityTests {
    // MARK: - The census

    /// One model, one render, and every model field the render doesn't carry
    /// verbatim — each with why.
    private struct Census {
        let name: String
        let model: Set<String>
        let render: Set<String>
        /// model field → why the render doesn't have a field of that name.
        let accountedFor: [String: String]

        init(
            _ name: String,
            model: Any,
            render: Any,
            accountedFor: [String: String] = [:]
        ) {
            self.name = name
            self.model = Self.fields(of: model)
            self.render = Self.fields(of: render)
            self.accountedFor = accountedFor
        }

        private static func fields(of value: Any) -> Set<String> {
            Set(Mirror(reflecting: value).children.compactMap(\.label))
        }
    }

    private func check(_ census: Census) {
        let unexplained = census.model.subtracting(census.render)
            .subtracting(census.accountedFor.keys)
        #expect(
            unexplained.isEmpty,
            """
            \(census.name): model field(s) \(unexplained.sorted()) reach no render field \
            and are not listed as deliberately folded or renamed. An agent cannot see them. \
            Either add them to the render or record the reason in this test's `accountedFor`.
            """
        )
        let stale = Set(census.accountedFor.keys).subtracting(census.model)
        #expect(
            stale.isEmpty,
            "\(census.name): `accountedFor` explains \(stale.sorted()), which the model no longer has."
        )
    }

    // MARK: - Fixtures
    //
    // Values, not maximal values: `Mirror` reports a stored property whether or not
    // it holds anything, which is the whole reason the census reads properties
    // rather than an encoding.

    private var flow: Flow {
        Flow(
            request: CapturedRequest(method: "GET", url: "https://api.example.test/v1", headers: []),
            startedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private var pending: PendingBreakpoint {
        PendingBreakpoint(
            breakpointID: UUID(),
            phase: .request,
            method: "GET",
            url: "https://api.example.test/v1",
            requestHeaders: []
        )
    }

    private var bucket: FlowStats.Bucket {
        FlowStats.compute(flows: [flow], grouping: .host).total
    }

    // MARK: - Flows

    @Test func flowSummaryAndDetail_carryEveryModelField() {
        let flow = flow
        // Summary and detail are one render split in two — the detail merges its
        // keys over the summary's — so the census reads them together.
        check(Census(
            "Flow → get_recent_flows / get_flow_detail",
            model: flow,
            render: FlowSummaryRender(flow),
            accountedFor: [
                "request": "get_flow_detail renders it as `request` (FlowDetailRender); the summary lifts method/url out of it",
                "outcome": "folded: the sum type becomes `status` + `error` in the summary and `response` in the detail",
                "firstByteAt": "folded into the derived `ttfbMS` / `receiveMS`, which is what it exists to make answerable",
                "webSocketMessages": "folded into `webSocket` — a bare `true` + `wsMessageCount` in the summary, the frame log in the detail",
                "webSocketDroppedMessages": "folded into `captureTruncated` (summary) and `webSocket.framesNotRecorded` (detail)",
                "webSocketCaptureError": "folded into `captureTruncated` (summary) and `webSocket.captureStopped` (detail)",
            ]
        ))
    }

    @Test func capturedRequest_carriesEveryModelField() {
        let request = CapturedRequest(method: "GET", url: "https://a.test", headers: [])
        check(Census(
            "CapturedRequest → get_flow_detail.request",
            model: request,
            render: RenderedRequest(request, body: .text("")),
            accountedFor: [
                "fullBodyBytes": "renamed: `bodyCaptureTruncated` + `bodyBytesOnWire`, which say *why* the number is there",
            ]
        ))
    }

    @Test func capturedResponse_carriesEveryModelField() {
        let response = CapturedResponse(statusCode: 200, headers: [])
        check(Census(
            "CapturedResponse → get_flow_detail.response",
            model: response,
            render: RenderedResponse(response, body: .text("")),
            accountedFor: [
                "statusCode": "renamed to `status`, matching the summary's key for the same number",
                "fullBodyBytes": "renamed: `bodyCaptureTruncated` + `bodyBytesOnWire`",
            ]
        ))
    }

    @Test func sourceAttribution_carriesEveryModelField() {
        let app = SourceApp(name: "curl", pid: 1)
        check(Census(
            "SourceApp → flow.sourceApp",
            model: app,
            render: SourceAppRender(app),
            accountedFor: [
                "bundlePath": "deliberately absent: a filesystem path for the human's icon lookup, of no use to an agent and a needless disclosure",
            ]
        ))

        let device = SourceDevice(ip: "127.0.0.1", kind: .local)
        check(Census("SourceDevice → flow.sourceDevice", model: device, render: SourceDeviceRender(device)))
    }

    @Test func graphQL_carriesEveryModelField() {
        let operation = GraphQLOperation(kind: .query, operationName: "Q", query: "{ a }", variablesJSON: nil)
        check(Census(
            "GraphQLOperation → get_flow_detail.graphQL",
            model: operation,
            render: RenderedGraphQL(operation),
            accountedFor: [
                "variablesJSON": "renamed to `variables` — it is already JSON text, and the suffix said so twice",
            ]
        ))
    }

    // MARK: - Stats

    @Test func statsBucket_carriesEveryModelField() {
        check(Census(
            "FlowStats.Bucket → get_stats.buckets[]",
            model: bucket,
            render: StatsBucketRender(bucket),
            accountedFor: [
                "ttfb": "renamed to `ttfbMS`: the render names its unit, because an agent reading a bare number has to guess",
                "receive": "renamed to `receiveMS`",
                "duration": "renamed to `durationMS`",
            ]
        ))
    }

    @Test func statsDistribution_carriesEveryModelField() {
        let distribution = FlowStats.Distribution(p50: 1, p95: 2, max: 3, samples: 4)
        check(Census(
            "FlowStats.Distribution → get_stats ttfbMS/receiveMS/durationMS",
            model: distribution,
            render: DistributionRender(distribution)
        ))
    }

    // MARK: - Breakpoints

    @Test func breakpoint_carriesEveryModelField() {
        let breakpoint = Breakpoint(match: RuleMatch(urlPattern: "*"))
        check(Census(
            "Breakpoint → list_pending.armed[]",
            model: breakpoint,
            render: BreakpointRender(
                id: breakpoint.id.uuidString,
                match: RuleMatchRender(breakpoint.match),
                onRequest: breakpoint.onRequest,
                onResponse: breakpoint.onResponse,
                createdAt: breakpoint.createdAt,
                comment: breakpoint.comment
            )
        ))
    }

    @Test func ruleMatch_carriesEveryModelField() {
        let match = RuleMatch(urlPattern: "*")
        check(Census("RuleMatch → the `match` block", model: match, render: RuleMatchRender(match)))
    }

    @Test func pendingBreakpoint_carriesEveryModelField() {
        let pending = pending
        check(Census(
            "PendingBreakpoint → list_pending.pending[]",
            model: pending,
            render: PendingBreakpointRender(
                id: pending.id.uuidString,
                breakpointId: pending.breakpointID.uuidString,
                phase: pending.phase.rawValue,
                heldAt: pending.heldAt,
                request: PendingRequestRender(
                    method: pending.method, url: pending.url,
                    headers: [], body: .text("")
                ),
                response: nil
            ),
            accountedFor: [
                "breakpointID": "cased as `breakpointId` — JSON keys here are lowerCamel throughout, and `ID` would be the only shout",
                "method": "nested under `request`, where a held exchange's request belongs",
                "url": "nested under `request`",
                "requestHeaders": "nested as `request.headers`",
                "requestBody": "nested as `request.body`, through the same body window a flow's uses",
                "statusCode": "nested as `response.status`, and only in the response phase",
                "responseHeaders": "nested as `response.headers`",
                "responseBody": "nested as `response.body`",
            ]
        ))
    }

    // MARK: - The encoding contract itself

    /// The three body shapes must stay distinguishable: an agent has to be able to
    /// tell "no body" from "2 MB of PNG" from "the first 16 KB of a large JSON".
    @Test func renderedBody_keepsTheThreeShapesApart() throws {
        // No body renders as an empty string, not as an object and not as null:
        // "there was no body" is an answer, and it has always been spelled `""`.
        #expect(MCPRender.dict(Wrapper(body: MCPToolExecutor.bodyField(nil)))["body"] as? String == "")

        let text = MCPRender.dict(Wrapper(body: MCPToolExecutor.bodyField(Data("hi".utf8))))
        #expect(text["body"] as? String == "hi")

        let binary = MCPRender.dict(Wrapper(body: MCPToolExecutor.bodyField(Data([0xFF, 0xFE, 0xFD]))))
        let binaryBody = try #require(binary["body"] as? [String: Any])
        #expect(binaryBody["binary"] as? Bool == true)
        #expect(binaryBody["bytes"] as? Int == 3)

        let windowed = MCPRender.dict(Wrapper(body: MCPToolExecutor.bodyField(Data("abcdef".utf8), offset: 1, maxBytes: 2)))
        let window = try #require(windowed["body"] as? [String: Any])
        #expect(window["truncated"] as? Bool == true)
        #expect(window["preview"] as? String == "bc")
        #expect(window["bytes"] as? Int == 6)
        #expect(window["offset"] as? Int == 1)
        #expect(window["nextOffset"] as? Int == 3)
    }

    /// A nil optional must be *absent*, not `null`: every render field is documented
    /// as "omitted when it doesn't apply", and a null would make an agent's
    /// `if "error" in flow` read true on a flow that succeeded.
    @Test func nilFields_areOmittedRatherThanNull() {
        let rendered = MCPToolExecutor.flowSummary(flow)
        #expect(rendered["error"] == nil)
        #expect(rendered["status"] == nil)
        #expect(rendered["sourceApp"] == nil)
        #expect(rendered["captureTruncated"] == nil)
        #expect(rendered.keys.contains("id"))
    }

    /// Timestamps stay ISO-8601 without fractional seconds — the format
    /// `get_recent_flows` has always emitted and `since` parses back.
    @Test func datesEncodeAsISO8601() {
        var flow = flow
        flow.startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(MCPToolExecutor.flowSummary(flow)["startedAt"] as? String == "2023-11-14T22:13:20Z")
    }

    private struct Wrapper: Encodable {
        var body: RenderedBody
    }
}
