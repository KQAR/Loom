import Foundation

/// An ordered HTTP header. Modeled as a list (not a dictionary) so we preserve
/// order and repeated header names exactly as they appeared on the wire. It is a
/// pure value (name + value) — no synthetic identity — so equality is value
/// equality (two identical headers compare equal), it encodes as just the wire
/// bytes, and replay/HAR round-trips don't mutate it. Views that need
/// `Identifiable` use positional identity (`ForEach(headers.indices, …)`).
public struct HeaderPair: Equatable, Codable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public extension [HeaderPair] {
    /// The first value whose header name matches case-insensitively (HTTP header
    /// names are case-insensitive), or nil. One definition of header-name equality
    /// for every layer that reads a header off a flow.
    func value(named name: String) -> String? {
        first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Whether any header matches `name` case-insensitively.
    func contains(named name: String) -> Bool {
        contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Drop every header whose name matches `name` case-insensitively — repeats
    /// included, since headers are an ordered list that can carry the same name
    /// twice. Uses `caseInsensitiveCompare` rather than `lowercased() ==` so a
    /// removal doesn't allocate a folded `String` per comparison.
    mutating func removeAll(named name: String) {
        removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Drop every header whose name matches any of `names` case-insensitively.
    /// Linear in `names` per header, which beats hashing a lowercased copy of every
    /// header name for the handful of names a rule or breakpoint edit removes.
    mutating func removeAll(namedAnyOf names: [String]) {
        guard !names.isEmpty else { return }
        removeAll { header in
            names.contains { $0.caseInsensitiveCompare(header.name) == .orderedSame }
        }
    }
}

public struct CapturedRequest: Equatable, Codable, Sendable {
    public var method: String
    public var url: String
    public var headers: [HeaderPair]
    public var body: Data?
    /// Total body bytes that crossed the wire, recorded **only** when `body` holds
    /// a capped prefix of them — i.e. the capture cap kicked in. Nil means `body`
    /// is the whole payload. The peer always received every byte; only Loom's
    /// recorded copy stops, and a reader must be able to tell. Optional so flows
    /// persisted before this field existed still decode.
    public var fullBodyBytes: Int?

    /// Whether `body` is a prefix of what actually flowed rather than the whole of it.
    public var isBodyTruncated: Bool { fullBodyBytes != nil }

    public init(method: String, url: String, headers: [HeaderPair], body: Data? = nil, fullBodyBytes: Int? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.fullBodyBytes = fullBodyBytes
    }
}

public struct CapturedResponse: Equatable, Codable, Sendable {
    public var statusCode: Int
    /// The HTTP version the upstream answered with (e.g. `HTTP/1.1`), or nil for a
    /// synthesized response (mock / block / mapLocal) that never hit the wire.
    public var httpVersion: String?
    public var headers: [HeaderPair]
    public var body: Data?
    /// Total body bytes that crossed the wire, recorded only when `body` holds a
    /// capped prefix of them (an SSE/long-poll/large download hitting the capture
    /// cap). Nil means `body` is complete. See `CapturedRequest.fullBodyBytes`.
    public var fullBodyBytes: Int?

    /// Whether `body` is a prefix of what actually flowed rather than the whole of it.
    public var isBodyTruncated: Bool { fullBodyBytes != nil }

    public init(
        statusCode: Int,
        httpVersion: String? = nil,
        headers: [HeaderPair],
        body: Data? = nil,
        fullBodyBytes: Int? = nil
    ) {
        self.statusCode = statusCode
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
        self.fullBodyBytes = fullBodyBytes
    }
}

/// The local process that originated a captured request, resolved from the
/// proxy connection's source port. Icon is not stored here (a UI concern derived
/// from `bundlePath`); the model stays AppKit-free so engine modules can build it.
public struct SourceApp: Equatable, Codable, Sendable, Hashable {
    /// Display name — bundle display/name if it's an app, else the executable's basename.
    public var name: String
    public var bundleID: String?
    /// Path to the `.app` bundle when the origin is a bundled app; the UI resolves
    /// the icon from this. Nil for CLI tools / daemons.
    public var bundlePath: String?
    public var pid: Int32

    public init(name: String, bundleID: String? = nil, bundlePath: String? = nil, pid: Int32) {
        self.name = name
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.pid = pid
    }

    /// Stable grouping key: bundle id when available, else the display name.
    public var groupingKey: String { bundleID ?? name }
}

/// Why a flow failed. A distinct type (not a bare `String`) so failure is
/// modeled explicitly and can grow structured fields later without churning
/// every call site.
public struct FlowError: Equatable, Codable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// One traffic rule that acted on a flow — the audit trail for "what did the
/// rules do to my traffic". Carries the rule's `id` (so the UI/MCP can link back
/// to the live rule) alongside the display `name`.
public struct AppliedRule: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Where a flow is in its lifecycle. Modeled as a sum type so the illegal
/// combinations the old triple of optionals allowed — a `completedAt` with no
/// response, a response *and* an error on a still-"pending" flow — are simply
/// unrepresentable. `.streaming` covers the window where the response head is
/// known but the body is still arriving (SSE / long-poll / a growing WebSocket).
public enum FlowOutcome: Equatable, Codable, Sendable {
    /// Request sent; no response head yet.
    case pending
    /// Response head known, body still arriving. Not terminal (no `completedAt`).
    case streaming(CapturedResponse)
    /// Finished normally at `at`.
    case completed(CapturedResponse, at: Date)
    /// Failed at `at`; `partialResponse` holds whatever arrived before the error
    /// (a mid-stream failure), or nil if it failed before the head.
    case failed(FlowError, at: Date, partialResponse: CapturedResponse?)
}

/// A single captured (or replayed) request/response exchange.
public struct Flow: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var request: CapturedRequest
    public var startedAt: Date
    /// Lifecycle + response/error, modeled so illegal states can't occur.
    public var outcome: FlowOutcome
    /// When the response *head* arrived — the first byte back from upstream.
    /// Splits the exchange into server think-time (`ttfbMS`) and transfer time
    /// (`receiveMS`), which a single `durationMS` cannot: "this call is slow" has
    /// completely different causes depending on which half it lands in. Nil while
    /// pending, for a flow that failed before any head, and for flows captured
    /// before this was recorded.
    public var firstByteAt: Date?
    /// Non-nil when this flow was produced by replaying another flow.
    public var replayedFrom: UUID?
    /// The local app/process that made the request, when it could be resolved.
    public var sourceApp: SourceApp?
    /// The device the request came from (this Mac or a LAN device), identified by
    /// the connection's remote IP and typed from its User-Agent.
    public var sourceDevice: SourceDevice?
    /// Traffic rules that acted on this exchange (mocked, rewrote, re-mapped,
    /// blocked or delayed it), in the order they applied. Nil when the exchange
    /// passed through untouched.
    public var appliedRules: [AppliedRule]?
    /// Non-nil once this flow is a WebSocket connection (its HTTP upgrade
    /// succeeded); frames captured in either direction append here over time.
    public var webSocketMessages: [WebSocketMessage]?
    /// Frames the capture cap dropped from `webSocketMessages` (they were still
    /// relayed to the peer). Nil when nothing was dropped — so a reader can tell a
    /// complete frame log from a partial one.
    public var webSocketDroppedMessages: Int?
    /// Set when this flow was loaded from a file (a HAR import) rather than observed
    /// on the wire, naming where it came from. Imported traffic sits in the same
    /// store as captured traffic — that's the point, it can be inspected, diffed and
    /// replayed the same way — so it has to be labelled, or a reader would take
    /// someone else's capture for something that just happened on this machine.
    public var importedFrom: String?

    public init(
        id: UUID = UUID(),
        request: CapturedRequest,
        startedAt: Date,
        outcome: FlowOutcome = .pending,
        firstByteAt: Date? = nil,
        replayedFrom: UUID? = nil,
        sourceApp: SourceApp? = nil,
        sourceDevice: SourceDevice? = nil,
        appliedRules: [AppliedRule]? = nil,
        webSocketMessages: [WebSocketMessage]? = nil,
        webSocketDroppedMessages: Int? = nil,
        importedFrom: String? = nil
    ) {
        self.id = id
        self.request = request
        self.startedAt = startedAt
        self.outcome = outcome
        self.firstByteAt = firstByteAt
        self.replayedFrom = replayedFrom
        self.sourceApp = sourceApp
        self.sourceDevice = sourceDevice
        self.appliedRules = appliedRules
        self.webSocketMessages = webSocketMessages
        self.webSocketDroppedMessages = webSocketDroppedMessages
        self.importedFrom = importedFrom
    }

    // MARK: Read accessors derived from `outcome` (keep call sites terse)

    /// The response, real or partial — nil only while still `.pending`.
    public var response: CapturedResponse? {
        switch outcome {
        case .pending: return nil
        case let .streaming(r): return r
        case let .completed(r, _): return r
        case let .failed(_, _, partial): return partial
        }
    }

    /// When the exchange reached a terminal state; nil while pending/streaming.
    public var completedAt: Date? {
        switch outcome {
        case .pending, .streaming: return nil
        case let .completed(_, at): return at
        case let .failed(_, at, _): return at
        }
    }

    public var flowError: FlowError? {
        if case let .failed(error, _, _) = outcome { return error }
        return nil
    }

    /// Failure message, for the many call sites that just want the text.
    public var error: String? { flowError?.message }

    /// True once the exchange upgraded to WebSocket.
    public var isWebSocket: Bool { webSocketMessages != nil }

    public var statusCode: Int? { response?.statusCode }

    /// Host of the request URL. Read on every render of a host-filtered list, on
    /// every `FlowQuery` candidate and on every persistence write, so it goes
    /// through `URLHost` (a direct authority scan, falling back to `URLComponents`
    /// for unusual shapes) rather than building a `URLComponents` each time.
    public var host: String? {
        URLHost.host(ofURLString: request.url)
    }

    /// Rounded, not truncated: a 49.9 ms exchange is 50 ms, not 49 ms. The difference
    /// is invisible one flow at a time and systematic in aggregate — truncation biases
    /// every percentile in `FlowStats` downward by up to a millisecond.
    public var durationMS: Int? {
        guard let completedAt else { return nil }
        return Int((completedAt.timeIntervalSince(startedAt) * 1000).rounded())
    }

    /// Time to first byte: request sent → response head back. This is the part the
    /// server is responsible for; `receiveMS` is the part the payload size and the
    /// link are responsible for.
    public var ttfbMS: Int? {
        guard let firstByteAt else { return nil }
        return Int((max(0, firstByteAt.timeIntervalSince(startedAt)) * 1000).rounded())
    }

    /// Response head → last byte: how long the body took to transfer.
    public var receiveMS: Int? {
        guard let firstByteAt, let completedAt else { return nil }
        return Int((max(0, completedAt.timeIntervalSince(firstByteAt)) * 1000).rounded())
    }
}
