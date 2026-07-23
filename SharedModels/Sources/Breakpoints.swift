import Foundation

/// Which side of an exchange a breakpoint pauses. A breakpoint can pause the
/// request (before it is forwarded upstream), the response (before it reaches the
/// client), or both.
public enum BreakpointPhase: String, Codable, Sendable, Equatable {
    case request
    case response
}

/// An armed breakpoint: traffic matching `match` is held mid-flight so an operator
/// (typically an AI over MCP) can inspect and edit it before it continues. Reuses
/// `RuleMatch` so matching semantics — and the MCP schema the agent already knows —
/// are identical to traffic rules. Breakpoints are intentionally *not* persisted:
/// a paused request holds a live connection open, so it can't outlive the process,
/// and an armed breakpoint silently surviving a relaunch would surprise the owner.
public struct Breakpoint: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var match: RuleMatch
    /// Pause the request before it is forwarded upstream.
    public var onRequest: Bool
    /// Pause the response before it is relayed back to the client.
    public var onResponse: Bool
    public var comment: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        match: RuleMatch,
        onRequest: Bool = true,
        onResponse: Bool = false,
        comment: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.match = match
        self.onRequest = onRequest
        self.onResponse = onResponse
        self.comment = comment
        self.createdAt = createdAt
    }

    /// Why this breakpoint is unusable, or nil when valid.
    public var validationError: String? {
        if match.urlPattern.isEmpty { return "match.url_pattern must not be empty" }
        if !onRequest, !onResponse { return "a breakpoint must pause on the request, the response, or both" }
        return nil
    }
}

/// A held (paused) exchange awaiting a `resume` decision. Self-contained — it
/// carries the full request (and, for a response-phase pause, the response) so the
/// agent can decide edits from `list_pending` alone, with no follow-up lookup.
public struct PendingBreakpoint: Identifiable, Equatable, Codable, Sendable {
    /// The id `resume` targets (distinct from the breakpoint's id — one breakpoint
    /// can hold many exchanges at once).
    public var id: UUID
    public var breakpointID: UUID
    public var phase: BreakpointPhase
    public var method: String
    public var url: String
    public var requestHeaders: [HeaderPair]
    public var requestBody: Data?
    /// Response fields, populated only for a `.response`-phase pause.
    public var statusCode: Int?
    public var responseHeaders: [HeaderPair]?
    public var responseBody: Data?
    public var heldAt: Date

    public init(
        id: UUID = UUID(),
        breakpointID: UUID,
        phase: BreakpointPhase,
        method: String,
        url: String,
        requestHeaders: [HeaderPair],
        requestBody: Data? = nil,
        statusCode: Int? = nil,
        responseHeaders: [HeaderPair]? = nil,
        responseBody: Data? = nil,
        heldAt: Date = Date()
    ) {
        self.id = id
        self.breakpointID = breakpointID
        self.phase = phase
        self.method = method
        self.url = url
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.statusCode = statusCode
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.heldAt = heldAt
    }
}

/// Edits applied when resuming a held exchange. Request-phase pauses honor
/// `method`/`url`; response-phase pauses honor `statusCode`; both honor the header
/// and body edits. Every field is optional (nil = leave as held); the body uses
/// `BodyOverride` for the same reason `ReplayOverrides` does.
public struct BreakpointEdit: Equatable, Sendable {
    public var method: String?
    public var url: String?
    public var statusCode: Int?
    public var setHeaders: [HeaderPair]?
    public var removeHeaders: [String]?
    public var body: BodyOverride

    public init(
        method: String? = nil,
        url: String? = nil,
        statusCode: Int? = nil,
        setHeaders: [HeaderPair]? = nil,
        removeHeaders: [String]? = nil,
        body: BodyOverride = .keep
    ) {
        self.method = method
        self.url = url
        self.statusCode = statusCode
        self.setHeaders = setHeaders
        self.removeHeaders = removeHeaders
        self.body = body
    }

    public static let none = BreakpointEdit()
}
