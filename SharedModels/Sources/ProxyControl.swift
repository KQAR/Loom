import Foundation

/// How the request body should change on replay. A single sum type instead of a
/// `body: Data?` + `clearBody: Bool` pair, whose fourth combination (a body *and*
/// clearBody) was a representable illegal state.
public enum BodyOverride: Equatable, Codable, Sendable {
    /// Keep the source flow's body (the default).
    case keep
    /// Send an empty body.
    case clear
    /// Replace with these bytes.
    case replace(Data)
}

/// How a flow should be mutated before being (re)sent. `method`/`url`/headers are
/// optional (nil = "leave as the source flow had it"); the body uses `BodyOverride`.
public struct ReplayOverrides: Equatable, Codable, Sendable {
    public var method: String?
    public var url: String?
    /// Headers to add or overwrite (matched case-insensitively by name).
    public var setHeaders: [HeaderPair]?
    /// Header names to remove (matched case-insensitively).
    public var removeHeaders: [String]?
    public var body: BodyOverride

    public init(
        method: String? = nil,
        url: String? = nil,
        setHeaders: [HeaderPair]? = nil,
        removeHeaders: [String]? = nil,
        body: BodyOverride = .keep
    ) {
        self.method = method
        self.url = url
        self.setHeaders = setHeaders
        self.removeHeaders = removeHeaders
        self.body = body
    }

    public static let none = ReplayOverrides()
}

public struct ProxyStatus: Equatable, Codable, Sendable {
    public var isRunning: Bool
    public var port: Int
    public var capturedCount: Int
    /// Whether observed traffic is being stored as flows. When false the proxy
    /// keeps forwarding (and MITM-decrypting) traffic but records nothing new.
    public var isRecording: Bool

    public init(isRunning: Bool, port: Int, capturedCount: Int, isRecording: Bool = true) {
        self.isRunning = isRunning
        self.port = port
        self.capturedCount = capturedCount
        self.isRecording = isRecording
    }
}

public enum ProxyControlError: Error, Equatable, Sendable {
    case flowNotFound(UUID)
    case invalidURL(String)
    case replayFailed(String)
    case certificateUnavailable(String)
    case ruleNotFound(UUID)
    case invalidRule(String)
    case phoneOnboardingUnavailable(String)
    case breakpointNotFound(UUID)
    case pendingBreakpointNotFound(UUID)
    case invalidBreakpoint(String)

    /// Human-readable text for surfacing to the operator (UI or AI), instead of a
    /// `String(describing:)` enum dump.
    public var message: String {
        switch self {
        case let .flowNotFound(id): return "no flow with id \(id.uuidString)"
        case let .invalidURL(url): return "invalid URL: \(url)"
        case let .replayFailed(reason): return "replay failed: \(reason)"
        case let .certificateUnavailable(reason): return "certificate unavailable: \(reason)"
        case let .ruleNotFound(id): return "no rule with id \(id.uuidString)"
        case let .invalidRule(reason): return "invalid rule: \(reason)"
        case let .phoneOnboardingUnavailable(reason): return "phone onboarding unavailable: \(reason)"
        case let .breakpointNotFound(id): return "no breakpoint with id \(id.uuidString)"
        case let .pendingBreakpointNotFound(id): return "no held (pending) breakpoint with id \(id.uuidString) — it may have already resumed or timed out"
        case let .invalidBreakpoint(reason): return "invalid breakpoint: \(reason)"
        }
    }
}

/// Read side of the engine — what the MCP server and TCA client both query.
public protocol FlowProviding: Sendable {
    func status() async -> ProxyStatus
    func recentFlows(limit: Int) async -> [Flow]
    /// Like `recentFlows`, but with request/response bodies hydrated — for
    /// exports (HAR) that need the full payload, not just summaries. Kept
    /// separate so the common list/summary path stays body-free (cheap).
    func recentFlowsForExport(limit: Int) async -> [Flow]
    func flow(id: UUID) async -> Flow?
    /// A live stream of flows as they are captured or updated.
    ///
    /// ## Emission contract
    /// Consumers (including "Loom as a backend" embedders) can rely on the
    /// following. The push `FlowObserving` sink delivers the identical sequence.
    ///
    /// - **Same id, multiple emissions.** A flow is emitted when capture starts
    ///   (`outcome == .pending`) and again on each state change through to a
    ///   terminal outcome (`.completed` / `.failed`). Dedupe/replace by
    ///   `Flow.id`; the latest emission for an id supersedes earlier ones.
    /// - **Streaming responses** emit intermediate `.streaming` updates between
    ///   start and completion.
    /// - **WebSocket** flows re-emit once per recorded frame, each carrying the
    ///   grown `webSocketMessages` (capped; see the WS relay). A `ws://`/`wss://`
    ///   exchange is one long-lived flow, not one flow per frame.
    /// - **HTTP/2** streams surface as independent flows (one per h2 stream),
    ///   same shape as HTTP/1.1 — no multiplexing is exposed to the consumer.
    /// - **Replays re-appear** on the stream, distinguished only by
    ///   `Flow.replayedFrom != nil` (the source flow's id). A consumer that
    ///   maps flows onto its own request/response events skips these to avoid
    ///   echoing a replay it initiated.
    /// - **Device attribution.** `sourceDevice` is populated from the
    ///   connection's remote IP (typed by `User-Agent`) for every capture,
    ///   loopback or LAN; `sourceApp` is resolved via libproc for loopback
    ///   traffic only (a LAN device has no local pid).
    /// - **Ordering / buffering.** Emissions preserve per-flow order. The stream
    ///   is unbuffered fan-out: a subscriber that starts late misses prior
    ///   emissions (seed from `recentFlows(limit:)` if you need history).
    func flowStream() async -> AsyncStream<Flow>
    /// Distinct devices that have sent traffic through the proxy (this Mac + LAN
    /// devices), with per-device flow counts and last-seen time.
    func connectedDevices() async -> [DeviceSummary]
}

/// Write side of the engine — the differentiator: AI (or the UI) can act.
public protocol FlowReplaying: Sendable {
    /// Re-send an existing flow's request with the given overrides applied,
    /// returning the newly captured flow for the replayed exchange. The source
    /// flow is resolved from the engine's in-memory ring, so this fails with
    /// `flowNotFound` once the source has aged out of the ring (see
    /// `replay(flow:overrides:)` for a retention-independent form).
    func replay(id: UUID, overrides: ReplayOverrides) async throws -> Flow

    /// Re-send `flow`'s request with the given overrides applied, without looking
    /// the source up in the engine's store. For an embedder that keeps captured
    /// flows in its own store (e.g. `ProxyEngine(persistFlows: false)`): the
    /// source can be replayed directly even after it has aged out of — or was
    /// never kept in — Loom's in-memory ring. The returned flow's `replayedFrom`
    /// is set to `flow.id`.
    func replay(flow: Flow, overrides: ReplayOverrides) async throws -> Flow
}

/// Capture gating: pause/resume storing observed traffic as flows. Pausing
/// never interrupts forwarding — traffic keeps flowing, it just isn't recorded.
public protocol CaptureControlling: Sendable {
    func setRecording(_ recording: Bool) async
}

/// A push-based sink for flow updates, for an embedder that keeps captured flows
/// in its own store and wants them delivered rather than polling/consuming
/// `flowStream()`. Register one via `ProxyEngine(persistFlows:capacity:observer:)`.
///
/// Delivers the **same** payload, with the same emission contract, as
/// `flowStream()`: a flow is pushed on capture start and again on
/// completion/failure (a streaming flow may be pushed several times as it
/// progresses; a WebSocket flow once per recorded frame), and replayed flows
/// arrive with `replayedFrom != nil`. Called from the store's actor, so keep the
/// implementation cheap and non-blocking (hand off heavy work).
///
/// Combined with `replay(flow:overrides:)` and `capacity: 0` (store-less), an
/// embedder can run the engine with zero internal retention — flows land only in
/// the embedder's store via this sink.
public protocol FlowObserving: Sendable {
    func flowDidUpdate(_ flow: Flow)
}

/// Breakpoints: hold matching traffic mid-flight so an operator (AI over MCP or
/// the UI) can inspect and edit it, then release it. A poll model — MCP has no
/// server push — so held exchanges surface via `pendingBreakpoints()` and are
/// released with `resumeBreakpoint`.
public protocol BreakpointControlling: Sendable {
    /// Arm a breakpoint. Throws `ProxyControlError.invalidBreakpoint` if malformed.
    func armBreakpoint(_ breakpoint: Breakpoint) async throws
    /// Remove an armed breakpoint. Does not affect exchanges already held by it —
    /// those still need a `resumeBreakpoint`. Throws if no such breakpoint.
    func disarmBreakpoint(id: UUID) async throws
    /// Currently armed breakpoints.
    func armedBreakpoints() async -> [Breakpoint]
    /// Exchanges held right now, awaiting a resume decision.
    func pendingBreakpoints() async -> [PendingBreakpoint]
    /// Release a held exchange: apply `edit` and continue, or `abort` to fail it
    /// with a 502. Throws `ProxyControlError.pendingBreakpointNotFound` if the id
    /// isn't held (already resumed or timed out).
    func resumeBreakpoint(pendingID: UUID, abort: Bool, edit: BreakpointEdit) async throws
}

/// The write-action audit trail. The MCP server records every write tool call
/// here (success or failure); the supervising human reads it in the main-window
/// Audit panel, and an agent can read it back via the `get_audit_log` tool.
/// Reads are never recorded — only writes, which are the actions that touch real
/// traffic.
public protocol AuditControlling: Sendable {
    /// Append one write-action record. Called from the MCP tool choke point.
    func recordAudit(_ entry: AuditEntry) async
    /// Most-recent-first audit entries, up to `limit`.
    func recentAuditEntries(limit: Int) async -> [AuditEntry]
    /// A live stream of audit entries as they are recorded, for the human panel.
    /// Like `flowStream()`, it is unbuffered fan-out — a late subscriber misses
    /// prior entries (seed from `recentAuditEntries(limit:)`).
    func auditStream() async -> AsyncStream<AuditEntry>
    /// Clear the entire audit trail — the in-memory ring and the durable store.
    func clearAudit() async
}

public typealias ProxyControlling = FlowProviding & FlowReplaying & TLSInterceptControlling & CaptureControlling & RulesControlling & BreakpointControlling & AuditControlling
