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
    public var headers: [HeaderPair]
    public var body: Data?

    public init(statusCode: Int, headers: [HeaderPair], body: Data? = nil) {
        self.statusCode = statusCode
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

/// A single captured (or replayed) request/response exchange.
public struct Flow: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var request: CapturedRequest
    public var response: CapturedResponse?
    public var startedAt: Date
    public var completedAt: Date?
    public var error: String?
    /// Non-nil when this flow was produced by replaying another flow.
    public var replayedFrom: UUID?
    /// The local app/process that made the request, when it could be resolved.
    public var sourceApp: SourceApp?
    /// Names of traffic rules that acted on this exchange (mocked, rewrote,
    /// re-mapped, blocked or delayed it), in the order they applied. Nil when
    /// the exchange passed through untouched — the audit trail for "what did
    /// the rules do to my traffic".
    public var appliedRules: [String]?
    /// Non-nil once this flow is a WebSocket connection (its HTTP upgrade
    /// succeeded); frames captured in either direction append here over time.
    public var webSocketMessages: [WebSocketMessage]?

    public init(
        id: UUID = UUID(),
        request: CapturedRequest,
        response: CapturedResponse? = nil,
        startedAt: Date,
        completedAt: Date? = nil,
        error: String? = nil,
        replayedFrom: UUID? = nil,
        sourceApp: SourceApp? = nil,
        appliedRules: [String]? = nil,
        webSocketMessages: [WebSocketMessage]? = nil
    ) {
        self.id = id
        self.request = request
        self.response = response
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.error = error
        self.replayedFrom = replayedFrom
        self.sourceApp = sourceApp
        self.appliedRules = appliedRules
        self.webSocketMessages = webSocketMessages
    }

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
