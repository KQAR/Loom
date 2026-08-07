import Foundation
import LoomSharedModels

// The typed renders. One `Encodable` value per thing an agent reads, built from
// the domain model and encoded by `MCPRender`. See that file for why these exist
// rather than hand-built `[String: Any]`.
//
// Rules for writing a new one:
//
// - **A render field is a stored property.** Optional means "omitted when nil",
//   which is what the hand-built dictionaries did with `if let`.
// - **A flag that only ever means `true`** is `Bool?` set to `true` or left nil —
//   never `Bool` defaulting to `false`, which would add a key that was never there.
// - **Shaped fields are welcome.** These are not mirrors of the model: `ttfbMS` is
//   computed, `captureTruncated` folds four model fields into one answer, the body
//   is a window. That shaping is the render's job; keeping it in a type is the
//   point. `RenderParityTests` knows about deliberate omissions and foldings — go
//   add the reason there rather than dropping a field silently.

// MARK: - Flows

/// One flow as `get_recent_flows` lists it. Also the base of `get_flow_detail`,
/// which merges its own richer keys over this (see `MCPToolExecutor.flowDetail`).
struct FlowSummaryRender: Encodable {
    var id: String
    var method: String
    var url: String
    /// When it happened — without this an agent can't tell a flow from three hours
    /// ago from the one it just triggered, nor order across calls.
    var startedAt: Date
    var status: Int?
    var durationMS: Int?
    /// The duration split so "why is this slow" is answerable: ttfb is the server's
    /// share, receive is the payload's.
    var ttfbMS: Int?
    var receiveMS: Int?
    var error: String?
    var replayedFrom: String?
    /// Loaded from a file, not observed here — the one thing that must never be
    /// implicit about an imported flow.
    var importedFrom: String?
    var appliedRules: [String]?
    /// Present (and only ever `true`) on a WebSocket flow. `get_flow_detail`
    /// replaces this key with the frame log object.
    var webSocket: Bool?
    var wsMessageCount: Int?
    /// A partially-captured exchange, flagged in the *summary* too, so an agent
    /// knows a body is a prefix before it fetches (or diffs) the detail.
    var captureTruncated: Bool?
    var sourceApp: SourceAppRender?
    var sourceDevice: SourceDeviceRender?

    init(_ flow: Flow) {
        id = flow.id.uuidString
        method = flow.request.method
        url = flow.request.url
        startedAt = flow.startedAt
        status = flow.statusCode
        durationMS = flow.durationMS
        ttfbMS = flow.ttfbMS
        receiveMS = flow.receiveMS
        error = flow.error
        replayedFrom = flow.replayedFrom?.uuidString
        importedFrom = flow.importedFrom
        appliedRules = flow.appliedRules?.map(\.name)
        if let messages = flow.webSocketMessages {
            webSocket = true
            wsMessageCount = messages.count
        }
        if flow.request.isBodyTruncated || flow.response?.isBodyTruncated == true
            || flow.webSocketDroppedMessages != nil || flow.webSocketCaptureError != nil {
            captureTruncated = true
        }
        sourceApp = flow.sourceApp.map(SourceAppRender.init)
        sourceDevice = flow.sourceDevice.map(SourceDeviceRender.init)
    }
}

struct SourceAppRender: Encodable {
    var name: String
    var pid: Int
    var bundleID: String?

    init(_ app: SourceApp) {
        name = app.name
        pid = Int(app.pid)
        bundleID = app.bundleID
    }
}

struct SourceDeviceRender: Encodable {
    var ip: String
    var kind: String
    var platform: String?
    var client: String?

    init(_ device: SourceDevice) {
        ip = device.ip
        kind = device.kind.rawValue
        platform = device.platform
        client = device.client
    }
}

/// The keys `get_flow_detail` adds on top of the summary. Merged over it rather
/// than restating it, so the two renders can't disagree about a shared field —
/// and so `webSocket` can be a frame log here while staying a bare `true` there.
struct FlowDetailRender: Encodable {
    var request: RenderedRequest
    var response: RenderedResponse?
    var graphQL: RenderedGraphQL?
    var webSocket: RenderedWebSocket?
}

struct RenderedRequest: Encodable {
    var method: String
    var url: String
    var headers: [RenderedHeader]
    var body: RenderedBody
    /// Capture truncation is a different fact from the render window in `body`: the
    /// recorded copy itself is a prefix, so no `body_offset` can reach the rest.
    /// Say so explicitly, with the real wire size.
    var bodyCaptureTruncated: Bool?
    var bodyBytesOnWire: Int?

    init(_ request: CapturedRequest, body: RenderedBody) {
        method = request.method
        url = request.url
        headers = RenderedHeader.list(request.headers)
        self.body = body
        if let wireBytes = request.fullBodyBytes {
            bodyCaptureTruncated = true
            bodyBytesOnWire = wireBytes
        }
    }
}

struct RenderedResponse: Encodable {
    var status: Int
    var headers: [RenderedHeader]
    var body: RenderedBody
    var httpVersion: String?
    var bodyCaptureTruncated: Bool?
    var bodyBytesOnWire: Int?

    init(_ response: CapturedResponse, body: RenderedBody) {
        status = response.statusCode
        headers = RenderedHeader.list(response.headers)
        self.body = body
        httpVersion = response.httpVersion
        if let wireBytes = response.fullBodyBytes {
            bodyCaptureTruncated = true
            bodyBytesOnWire = wireBytes
        }
    }
}

struct RenderedGraphQL: Encodable {
    var kind: String
    var query: String
    var operationName: String?
    var variables: String?

    init(_ graphQL: GraphQLOperation) {
        kind = graphQL.kind.rawValue
        query = graphQL.query
        operationName = graphQL.operationName
        variables = graphQL.variablesJSON
    }
}

/// The frame log. Three different ways a frame can be missing, and they are not
/// interchangeable: the render cap (page for more), the capture cap (never
/// recorded), and a parse that gave up (nothing after this point was ever seen as
/// a frame).
struct RenderedWebSocket: Encodable {
    var messageCount: Int
    var messages: [RenderedWebSocketMessage]
    var messagesTruncated: Bool?
    var messagesShown: Int?
    var framesNotRecorded: Int?
    var captureStopped: String?
}

struct RenderedWebSocketMessage: Encodable {
    var direction: String
    var kind: String
    var isFinal: Bool
    var text: RenderedBody?
    var bytes: Int?
}

// MARK: - Stats

struct StatsBucketRender: Encodable {
    var key: String
    var flows: Int
    var errors: Int
    /// Rounded: three decimals is finer than any capture-sized sample justifies.
    var errorRate: Double
    var statusClasses: [String: Int]
    var requestBytes: Int
    var responseBytes: Int
    var failed: Int?
    var inFlight: Int?
    var ttfbMS: DistributionRender?
    /// Reported next to TTFB rather than left as durationMS - ttfbMS: telling "the
    /// server is slow" from "the payload is big" is what this tool is for, and a
    /// percentile of a difference is not the difference of percentiles.
    var receiveMS: DistributionRender?
    var durationMS: DistributionRender?
    /// Only surfaced when it applies — but never omitted when it does, because it is
    /// the difference between "this host sent 4 MB" and "at least 4 MB".
    var sizeUnknownFlows: Int?

    init(_ bucket: FlowStats.Bucket) {
        key = bucket.key
        flows = bucket.flows
        errors = bucket.errors
        errorRate = (bucket.errorRate * 1000).rounded() / 1000
        statusClasses = bucket.statusClasses
        requestBytes = bucket.requestBytes
        responseBytes = bucket.responseBytes
        failed = bucket.failed > 0 ? bucket.failed : nil
        inFlight = bucket.inFlight > 0 ? bucket.inFlight : nil
        ttfbMS = bucket.ttfb.map(DistributionRender.init)
        receiveMS = bucket.receive.map(DistributionRender.init)
        durationMS = bucket.duration.map(DistributionRender.init)
        sizeUnknownFlows = bucket.sizeUnknownFlows > 0 ? bucket.sizeUnknownFlows : nil
    }
}

struct DistributionRender: Encodable {
    var p50: Int
    var p95: Int
    var max: Int
    var samples: Int

    init(_ distribution: FlowStats.Distribution) {
        p50 = distribution.p50
        p95 = distribution.p95
        max = distribution.max
        samples = distribution.samples
    }
}

struct SlowestFlowRender: Encodable {
    var id: String
    var method: String
    var url: String
    var status: Int?
    var ttfbMS: Int?
    var durationMS: Int?

    init(_ slow: FlowStats.Slow) {
        id = slow.id.uuidString
        method = slow.method
        url = slow.url
        status = slow.statusCode
        ttfbMS = slow.ttfbMS
        durationMS = slow.durationMS
    }
}

// MARK: - Breakpoints

/// A rule/breakpoint predicate. Shared by `list_rules` and the breakpoint tools —
/// one render, because "what does this match" is one question whichever surface
/// asks it, and two copies would let the answers drift.
///
/// Empty is nil here: an empty `methods` or `query` means "no constraint", and
/// rendering it as `[]` reads like a constraint that matches nothing.
struct RuleMatchRender: Encodable {
    var urlPattern: String
    var isRegex: Bool?
    var isExact: Bool?
    var hostPattern: String?
    var query: [String: String]?
    var sourceApp: String?
    var deviceIP: String?
    var methods: [String]?

    init(_ match: RuleMatch) {
        urlPattern = match.urlPattern
        isRegex = match.isRegex ? true : nil
        isExact = match.isExact ? true : nil
        hostPattern = match.hostPattern.flatMap { $0.isEmpty ? nil : $0 }
        query = match.query.flatMap { $0.isEmpty ? nil : $0 }
        sourceApp = match.sourceApp.flatMap { $0.isEmpty ? nil : $0 }
        deviceIP = match.deviceIP.flatMap { $0.isEmpty ? nil : $0 }
        methods = match.methods.isEmpty ? nil : match.methods
    }
}

struct BreakpointRender: Encodable {
    var id: String
    var match: RuleMatchRender
    var onRequest: Bool
    var onResponse: Bool
    var createdAt: Date
    var comment: String?
}

/// A held exchange. `request` is always present (the phase can't be reached
/// without one); `response` only in the response phase, where the client is
/// waiting on bytes the origin has already sent.
struct PendingBreakpointRender: Encodable {
    var id: String
    var breakpointId: String
    var phase: String
    var heldAt: Date
    var request: PendingRequestRender
    var response: PendingResponseRender?
}

struct PendingRequestRender: Encodable {
    var method: String
    var url: String
    var headers: [RenderedHeader]
    var body: RenderedBody
}

struct PendingResponseRender: Encodable {
    var headers: [RenderedHeader]
    var body: RenderedBody
    var status: Int?
}

/// One attempt of a batch `replay_flow`. Deliberately *not* a `FlowSummaryRender`:
/// a batch of 50 replays rendered in full would bury the thing the caller asked
/// for (did they succeed, how fast, what failed) under 50 copies of the request
/// they already know they sent. `get_flow_detail` on an id is the way to the rest.
struct ReplayAttemptRender: Encodable {
    var id: String
    var status: Int?
    var ttfbMS: Int?
    var durationMS: Int?
    var error: String?

    init(_ flow: Flow) {
        id = flow.id.uuidString
        status = flow.statusCode
        ttfbMS = flow.ttfbMS
        durationMS = flow.durationMS
        error = flow.error
    }
}
