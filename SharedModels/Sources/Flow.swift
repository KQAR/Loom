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
}

public struct CapturedRequest: Equatable, Codable, Sendable {
    public var method: String
    public var url: String
    public var headers: [HeaderPair]
    public var body: Data?

    public init(method: String, url: String, headers: [HeaderPair], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct CapturedResponse: Equatable, Codable, Sendable {
    public var statusCode: Int
    /// The HTTP version the upstream answered with (e.g. `HTTP/1.1`), or nil for a
    /// synthesized response (mock / block / mapLocal) that never hit the wire.
    public var httpVersion: String?
    public var headers: [HeaderPair]
    public var body: Data?

    public init(statusCode: Int, httpVersion: String? = nil, headers: [HeaderPair], body: Data? = nil) {
        self.statusCode = statusCode
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
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
    /// Non-nil when this flow was produced by replaying another flow.
    public var replayedFrom: UUID?
    /// The local app/process that made the request, when it could be resolved.
    public var sourceApp: SourceApp?
    /// Traffic rules that acted on this exchange (mocked, rewrote, re-mapped,
    /// blocked or delayed it), in the order they applied. Nil when the exchange
    /// passed through untouched.
    public var appliedRules: [AppliedRule]?
    /// Non-nil once this flow is a WebSocket connection (its HTTP upgrade
    /// succeeded); frames captured in either direction append here over time.
    public var webSocketMessages: [WebSocketMessage]?

    public init(
        id: UUID = UUID(),
        request: CapturedRequest,
        startedAt: Date,
        outcome: FlowOutcome = .pending,
        replayedFrom: UUID? = nil,
        sourceApp: SourceApp? = nil,
        appliedRules: [AppliedRule]? = nil,
        webSocketMessages: [WebSocketMessage]? = nil
    ) {
        self.id = id
        self.request = request
        self.startedAt = startedAt
        self.outcome = outcome
        self.replayedFrom = replayedFrom
        self.sourceApp = sourceApp
        self.appliedRules = appliedRules
        self.webSocketMessages = webSocketMessages
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

    public var host: String? {
        URLComponents(string: request.url)?.host
    }

    public var durationMS: Int? {
        guard let completedAt else { return nil }
        return Int(completedAt.timeIntervalSince(startedAt) * 1000)
    }
}
