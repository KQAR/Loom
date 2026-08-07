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

// MARK: - Environment

/// `get_proxy_status`. Half of it is `ProxyStatus`; the rest is what the injected
/// `SystemRoutingControlling` knows, which the engine deliberately cannot reach
/// (the dependency direction is one-way). One render, because an agent asking
/// "why is nothing captured" needs both halves in the same answer.
struct ProxyStatusRender: Encodable {
    var isRunning: Bool
    var port: Int
    var listenHost: String
    var lanReachable: Bool
    var capturedCount: Int
    var isRecording: Bool
    /// Reported only when there is one to point at, so its absence is an answer
    /// rather than a zero to interpret.
    var socksPort: Int?
    /// Four-valued on purpose: `on` / `off` / `other` / `unavailable`. Collapsing
    /// "can't tell" into off would have an agent "fix" a routing problem it has no
    /// way to observe; collapsing "another app owns it" into off would have it
    /// silently steal the user's Charles/whistle configuration.
    var systemProxy: String
    var systemProxyPointsAt: String?
    var privilegedHelper: String?
    /// Whether `set_system_proxy` will stop and wait for a human at the machine.
    var systemProxyChangePrompts: Bool?
    var privilegedHelperDetail: String?
    /// All-time count — "this happened once" vs "this is happening to every request".
    var refusedConnections: Int?
    var recentRefusals: [ConnectionRefusalRender]?
    var reverseProxies: [ReverseProxyRender]?
}

struct ConnectionRefusalRender: Encodable {
    var at: Date
    var listener: String
    var reason: String
    var peer: String?

    init(_ refusal: ConnectionRefusal) {
        at = refusal.at
        listener = refusal.listener.rawValue
        reason = refusal.reason
        peer = refusal.peer
    }
}

/// One rendering, shared by `get_proxy_status`, `list_reverse_proxies` and
/// `create_reverse_proxy` — three places an agent reads the same fact, which is
/// three chances for them to disagree about what "listening" means.
struct ReverseProxyRender: Encodable {
    var id: String
    var upstream: String
    var listening: Bool
    var keepHostHeader: Bool
    var localURL: String?
    var label: String?
    /// Present exactly when it isn't listening, so the reason travels with the
    /// problem instead of having to be asked for separately.
    var error: String?

    init(_ status: ReverseProxyStatus) {
        id = status.endpoint.id.uuidString
        upstream = status.endpoint.upstream
        listening = status.isListening
        keepHostHeader = status.endpoint.keepHostHeader
        localURL = status.localURL
        label = status.endpoint.label
        error = status.error
    }
}

/// One entry for `list_devices`. Dates as ISO-8601 so the model can order them.
struct DeviceSummaryRender: Encodable {
    var ip: String
    var kind: String
    var displayName: String
    var flowCount: Int
    var lastActive: Date
    var platform: String?
    var client: String?
    var type: String?

    init(_ summary: DeviceSummary) {
        let device = summary.device
        ip = device.ip
        kind = device.kind.rawValue
        displayName = device.displayName
        flowCount = summary.flowCount
        lastActive = summary.lastActive
        platform = device.platform
        client = device.client
        type = device.typeSummary
    }
}

struct CertificateStatusRender: Encodable {
    var isGenerated: Bool
    var isTrusted: Bool
    var commonName: String?
    var sha256Fingerprint: String?
    var notAfter: Date?
    var exportedPEMPath: String?

    init(_ status: CertificateStatus) {
        isGenerated = status.isGenerated
        isTrusted = status.isTrusted
        commonName = status.commonName
        sha256Fingerprint = status.sha256Fingerprint
        notAfter = status.notAfter
        exportedPEMPath = status.exportedPEMPath
    }
}

struct SSLScopeRender: Encodable {
    var enabled: Bool
    var include: [String]
    var exclude: [String]
    /// Origins Loom relayed without reading. Here rather than behind a second call
    /// because an agent that has to ask twice reads an empty capture as "the client
    /// never ran" before it gets to the second ask.
    var tunneledHosts: [TunneledHostRender]?
    var tunneledHostsEvicted: Int?

    init(_ scope: SSLScope, tunneled: TunneledHostReport? = nil) {
        enabled = scope.enabled
        include = scope.include
        exclude = scope.exclude
        if let tunneled, !tunneled.hosts.isEmpty {
            tunneledHosts = tunneled.hosts.map(TunneledHostRender.init)
        }
        if let tunneled, tunneled.evicted > 0 { tunneledHostsEvicted = tunneled.evicted }
    }
}

/// One origin Loom relayed without reading. `interceptable` is carried rather than
/// left for the model to infer from `reason`, so the follow-up action is decidable
/// from the row.
struct TunneledHostRender: Encodable {
    var host: String
    var port: Int
    var connections: Int
    var firstSeen: Date
    var lastSeen: Date
    var reason: String
    var interceptable: Bool

    init(_ entry: TunneledHost) {
        host = entry.host
        port = entry.port
        connections = entry.connections
        firstSeen = entry.firstSeen
        lastSeen = entry.lastSeen
        reason = entry.reason.rawValue
        interceptable = entry.interceptable
    }
}

struct ClientCertificateRender: Encodable {
    var id: String
    var hostPattern: String
    var label: String
    var enabled: Bool
    var subject: String?
    var notAfter: Date?
    /// Stated rather than left to be derived from `notAfter`: an expired identity
    /// fails the handshake exactly like a missing one, and that is the diagnosis
    /// this list exists to shorten.
    var expired: Bool?
    var problem: String?

    init(_ summary: ClientCertificateSummary) {
        id = summary.id.uuidString
        hostPattern = summary.hostPattern
        label = summary.label
        enabled = summary.isEnabled
        subject = summary.subject
        notAfter = summary.notAfter
        expired = summary.notAfter == nil ? nil : summary.isExpired()
        problem = summary.problem
    }
}

/// One entry for `get_audit_log`. `arguments` is already-truncated compact JSON
/// (a string, deliberately not re-parsed — it is a record of what was sent, not a
/// structure to query).
struct AuditEntryRender: Encodable {
    var id: String
    var timestamp: Date
    var tool: String
    var source: String
    var succeeded: Bool
    var arguments: String
    var detail: String

    init(_ entry: AuditEntry) {
        id = entry.id.uuidString
        timestamp = entry.timestamp
        tool = entry.tool
        source = entry.source.rawValue
        succeeded = entry.succeeded
        arguments = entry.arguments
        detail = entry.detail
    }
}

// MARK: - Rules

/// One rule as `list_rules` shows it.
///
/// The render an agent reads back is not the schema it writes (`set_rule` takes
/// snake_case, this answers in lowerCamel) and not the model's own encoding —
/// three representations of one type, which is exactly the drift
/// `RuleCodecParityTests` exists to catch. Being a type here means the third one
/// is at least compiler-checked internally; the census keeps it honest against
/// the model.
struct RuleRender: Encodable {
    var id: String
    var name: String
    var enabled: Bool
    var match: RuleMatchRender
    var createdAt: Date
    var comment: String?
    var group: String?
    var actions: RuleActionsRender

    init(_ rule: TrafficRule, truncateBodies: Bool) {
        id = rule.id.uuidString
        name = rule.name
        enabled = rule.isEnabled
        match = RuleMatchRender(rule.match)
        createdAt = rule.createdAt
        comment = rule.comment
        group = rule.group
        actions = RuleActionsRender(rule.actions, truncateBodies: truncateBodies)
    }
}

/// What a rule does. Empty when it does nothing (`passthrough` with no rewrites) —
/// which is a legal rule, and rendering `{}` says so more honestly than omitting
/// the key would.
struct RuleActionsRender: Encodable {
    var block: Bool?
    var mockResponse: MockResponseRender?
    var mapRemote: MapRemoteRender?
    var mapLocal: MapLocalRender?
    var rewriteRequest: RequestRewriteRender?
    var rewriteResponse: ResponseRewriteRender?
    var requestSubstitutions: [SubstitutionRender]?
    var responseSubstitutions: [SubstitutionRender]?
    var delayMs: Int?

    init(_ actions: RuleActions, truncateBodies: Bool) {
        switch actions.route {
        case .passthrough:
            break
        case .block:
            block = true
        case let .mock(mock):
            mockResponse = MockResponseRender(mock, truncateBodies: truncateBodies)
        case let .mapRemote(map):
            mapRemote = MapRemoteRender(map)
        case let .mapLocal(map):
            mapLocal = MapLocalRender(map)
        }
        if let rewrite = actions.rewriteRequest, !rewrite.isEmpty {
            rewriteRequest = RequestRewriteRender(rewrite, truncateBodies: truncateBodies)
        }
        if let rewrite = actions.rewriteResponse, !rewrite.isEmpty {
            rewriteResponse = ResponseRewriteRender(rewrite, truncateBodies: truncateBodies)
        }
        let requests = actions.activeRequestSubstitutions
        if !requests.isEmpty { requestSubstitutions = requests.map(SubstitutionRender.init) }
        let responses = actions.activeResponseSubstitutions
        if !responses.isEmpty { responseSubstitutions = responses.map(SubstitutionRender.init) }
        delayMs = actions.delayMilliseconds
    }
}

/// A rule body in a *list*: cut to a preview plus its true length, so a rule set
/// with big JSON mocks doesn't flood the agent's context. `list_rules` truncates;
/// the single-rule renders (`set_rule`'s echo) do not, because that caller is
/// looking at exactly one body and asked for it.
struct TruncatedBodyRender {
    var body: String?
    var bodyLength: Int?
    var bodyTruncated: Bool?

    init(_ text: String?, truncate: Bool) {
        let limit = 200
        guard let text else { return }
        if truncate, text.count > limit {
            body = String(text.prefix(limit))
            bodyLength = text.count
            bodyTruncated = true
        } else {
            body = text
        }
    }
}

struct MockResponseRender: Encodable {
    var statusCode: Int
    var headers: [String: String]?
    var contentType: String?
    var body: String?
    var bodyLength: Int?
    var bodyTruncated: Bool?
    var bodyBase64: String?

    init(_ mock: MockResponseAction, truncateBodies: Bool) {
        statusCode = mock.statusCode
        headers = mock.headers.isEmpty ? nil : MCPToolExecutor.headerDict(mock.headers)
        contentType = mock.contentType
        let text = TruncatedBodyRender(mock.bodyText, truncate: truncateBodies)
        body = text.body
        bodyLength = text.bodyLength
        bodyTruncated = text.bodyTruncated
        // Base64 is capped separately and says how much was cut inline: it has no
        // preview worth reading, so the count *is* the information.
        bodyBase64 = mock.bodyBase64.map { base64 in
            truncateBodies && base64.count > 256
                ? String(base64.prefix(256)) + "…(\(base64.count) base64 chars)"
                : base64
        }
    }
}

struct MapRemoteRender: Encodable {
    var destination: String
    var exclude: String?
    var keepHostHeader: Bool?

    init(_ map: MapRemoteAction) {
        destination = map.destination
        exclude = map.excludePattern
        keepHostHeader = map.keepHostHeader ? true : nil
    }
}

struct MapLocalRender: Encodable {
    var path: String
    var statusCode: Int
    var contentType: String?

    init(_ map: MapLocalAction) {
        path = map.path
        statusCode = map.statusCode
        contentType = map.contentType
    }
}

struct RequestRewriteRender: Encodable {
    var method: String?
    var setHeaders: [String: String]?
    var removeHeaders: [String]?
    var body: String?
    var bodyLength: Int?
    var bodyTruncated: Bool?

    init(_ rewrite: RequestRewriteAction, truncateBodies: Bool) {
        method = rewrite.method
        setHeaders = rewrite.setHeaders.isEmpty ? nil : MCPToolExecutor.headerDict(rewrite.setHeaders)
        removeHeaders = rewrite.removeHeaders.isEmpty ? nil : rewrite.removeHeaders
        let text = TruncatedBodyRender(rewrite.bodyText, truncate: truncateBodies)
        body = text.body
        bodyLength = text.bodyLength
        bodyTruncated = text.bodyTruncated
    }
}

struct ResponseRewriteRender: Encodable {
    var statusCode: Int?
    var setHeaders: [String: String]?
    var removeHeaders: [String]?
    var body: String?
    var bodyLength: Int?
    var bodyTruncated: Bool?

    init(_ rewrite: ResponseRewriteAction, truncateBodies: Bool) {
        statusCode = rewrite.statusCode
        setHeaders = rewrite.setHeaders.isEmpty ? nil : MCPToolExecutor.headerDict(rewrite.setHeaders)
        removeHeaders = rewrite.removeHeaders.isEmpty ? nil : rewrite.removeHeaders
        let text = TruncatedBodyRender(rewrite.bodyText, truncate: truncateBodies)
        body = text.body
        bodyLength = text.bodyLength
        bodyTruncated = text.bodyTruncated
    }
}

struct SubstitutionRender: Encodable {
    var field: String
    var match: String
    var replacement: String
    var isRegex: Bool?
    var caseSensitive: Bool?

    init(_ sub: SubstitutionRule) {
        field = sub.field.rawValue
        match = sub.match
        replacement = sub.replacement
        isRegex = sub.isRegex ? true : nil
        caseSensitive = sub.caseSensitive ? true : nil
    }
}
