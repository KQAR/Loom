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
    /// Interface the listener is bound to: `127.0.0.1` (this Mac only) or `0.0.0.0`
    /// (also reachable from the LAN, as phone onboarding needs). Part of the status
    /// because "nothing is being captured" and "nothing can reach the proxy" look
    /// identical from the outside, and this is half the answer.
    public var listenHost: String
    /// Port of the SOCKS5 listener, or `nil` when there isn't one (an embedder that
    /// didn't ask for it, or a bind that failed — the engine fails open on that and
    /// this is how it says so). The other half of the same "is my traffic even
    /// reaching Loom" question `listenHost` answers: a client that only knows how to
    /// point at a SOCKS proxy needs this number, and a `nil` means pointing it there
    /// would go nowhere.
    public var socksPort: Int?
    /// Connections Loom accepted and then refused, newest first (bounded).
    ///
    /// The third answer to "why is nothing captured". `listenHost` and `socksPort`
    /// cover "nothing could reach the proxy"; the system-proxy state covers
    /// "nothing was routed here". Neither covers **something arrived and Loom said
    /// no** — a SOCKS4 client, an HTTP request sent to the SOCKS port, an
    /// unsupported command. Loom knows exactly what happened in those cases and
    /// used to keep it to itself (an `os_log` line the human could find in Console
    /// and an agent could not reach at all), so an empty capture looked identical
    /// to a client that never started.
    public var recentRefusals: [ConnectionRefusal]
    /// Refusals since launch, including any already dropped from `recentRefusals`
    /// — the difference between "this happened once" and "this is happening on
    /// every request".
    public var refusedConnections: Int

    public init(
        isRunning: Bool, port: Int, capturedCount: Int, isRecording: Bool = true,
        listenHost: String = "127.0.0.1", socksPort: Int? = nil,
        recentRefusals: [ConnectionRefusal] = [], refusedConnections: Int = 0
    ) {
        self.isRunning = isRunning
        self.port = port
        self.capturedCount = capturedCount
        self.isRecording = isRecording
        self.listenHost = listenHost
        self.socksPort = socksPort
        self.recentRefusals = recentRefusals
        self.refusedConnections = refusedConnections
    }

    /// Reachable from other devices on the network, not just this Mac.
    public var isLANReachable: Bool { listenHost == "0.0.0.0" }
}

/// One connection Loom accepted and then closed without capturing anything.
///
/// Deliberately not a `Flow`: no exchange happened, there is no request to
/// inspect, and putting these in the capture would mean every read surface had to
/// learn about a row with no method and no URL. It answers one question — "did
/// something reach the proxy and get turned away, and why" — so it carries only
/// what that answer needs.
public struct ConnectionRefusal: Equatable, Codable, Sendable, Identifiable {
    /// Which listener refused it: a client aimed at the wrong one of the two ports
    /// is the single most likely cause, so naming the port is half the diagnosis.
    public enum Listener: String, Codable, Sendable {
        case http
        case socks
    }

    public var id: UUID
    public var at: Date
    public var listener: Listener
    /// Peer address as seen by the listener, or nil if it was already gone.
    public var peer: String?
    /// What Loom refused and why, in terms the operator can act on.
    public var reason: String

    public init(
        id: UUID = UUID(), at: Date = Date(), listener: Listener,
        peer: String? = nil, reason: String
    ) {
        self.id = id
        self.at = at
        self.listener = listener
        self.peer = peer
        self.reason = reason
    }
}

/// Whether this Mac's own traffic is routed through Loom, and the switch for it.
///
/// Lives here as a protocol, and is *injected into* the MCP server, because turning
/// the system proxy on means `networksetup` + a pf anchor for QUIC — client-layer
/// code the engine must not depend on (the dependency direction is one-way:
/// App → Features → Clients → Engine). The engine-side tools get an abstraction; the
/// app supplies the implementation at boot.
///
/// The reason it is exposed to an agent at all: an empty capture has two very
/// different causes — nothing happened, or nothing was routed here — and an agent
/// that can't tell them apart guesses. `nil` (no implementation wired) is itself an
/// honest answer, reported as "unavailable" rather than as "off".
public protocol SystemRoutingControlling: Sendable {
    /// Is the system proxy currently pointing this Mac's HTTP/HTTPS traffic at Loom?
    func isSystemProxyActive() async -> Bool
    /// Where this Mac's traffic actually goes. Strictly more informative than
    /// `isSystemProxyActive()`: it separates "no proxy set" from "another proxy owns
    /// it", which are the same `false` to the boolean and *different* advice to give.
    func systemProxyRouting() async -> SystemProxyRouting
    /// Point this Mac's traffic at Loom (or stop). May prompt for an admin password
    /// on a non-admin account, and also toggles the QUIC block that forces browsers
    /// off HTTP/3 (which a TCP proxy cannot see).
    func setSystemProxy(enabled: Bool) async -> SystemRoutingResult
}

public struct SystemRoutingResult: Equatable, Sendable {
    public var ok: Bool
    public var message: String?

    public init(ok: Bool, message: String? = nil) {
        self.ok = ok
        self.message = message
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
    case invalidClientCertificate(String)
    case clientCertificateNotFound(UUID)

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
        case let .invalidClientCertificate(reason): return "invalid client certificate: \(reason)"
        case let .clientCertificateNotFound(id): return "no client certificate with id \(id.uuidString)"
        }
    }
}

/// Read side of the engine — what the MCP server and TCA client both query.
public protocol FlowProviding: Sendable {
    func status() async -> ProxyStatus
    func recentFlows(limit: Int) async -> [Flow]
    /// Newest-first flows matching `query`, capped at `limit`.
    ///
    /// The filter is applied **before** the limit, over everything retained — the
    /// whole point is that "the 3 failed calls to api.example.com" can be found
    /// even when they aren't among the newest `limit` exchanges. A default
    /// implementation filters `recentFlows`; an implementor holding a store should
    /// override it so the scan happens next to the data.
    func recentFlows(matching query: FlowQuery, limit: Int) async -> [Flow]
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
    /// Fires whenever the captured set is discarded (`clearFlows`), whoever asked
    /// — the human's Clear button or an agent's `clear_flows` tool.
    ///
    /// `flowStream()` can't carry this: it emits flows, and "everything is gone"
    /// isn't a flow. Without the signal, a surface that clears its own list only
    /// on its own button keeps displaying flows the store no longer has after an
    /// agent clears — the human would be supervising a stale view.
    func flowsClearedStream() async -> AsyncStream<Void>
}

public extension FlowProviding {
    /// Conformers that never clear (or don't care) get a stream that simply never
    /// fires, so this stays an additive requirement for embedders.
    func flowsClearedStream() async -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }

    /// Fallback for conformers without their own store: pull a generous window and
    /// filter it here. Correct, but scans only what `recentFlows` returns — an
    /// implementor with a store should override.
    func recentFlows(matching query: FlowQuery, limit: Int) async -> [Flow] {
        guard !query.isEmpty else { return await recentFlows(limit: limit) }
        let candidates = await recentFlows(limit: max(limit, 2_000))
        return Array(candidates.lazy.filter(query.matches).prefix(max(0, limit)))
    }
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

/// Capture gating: pause/resume storing observed traffic as flows, and discard
/// what's been captured. Pausing never interrupts forwarding — traffic keeps
/// flowing, it just isn't recorded.
public protocol CaptureControlling: Sendable {
    /// Load flows that were not observed on the wire (a HAR import) into the store,
    /// so they can be inspected, diffed and replayed like captured ones. Returns how
    /// many landed. Recorded even while capture is paused — an import is an explicit
    /// action, like a replay.
    ///
    /// Default implementation stores nothing and returns 0, for an embedder that owns
    /// its own retention; the count is the caller's signal, so "nothing was imported"
    /// is visible rather than assumed.
    func importFlows(_ flows: [Flow]) async -> Int
    func setRecording(_ recording: Bool) async
    /// Discard every captured flow — the in-memory ring and the durable store.
    /// Destructive and not undoable. Observers learn about it via
    /// `FlowProviding.flowsClearedStream()`, so a surface showing the old flows
    /// doesn't keep presenting them as current.
    func clearFlows() async
}

public extension CaptureControlling {
    func importFlows(_ flows: [Flow]) async -> Int { 0 }
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
/// the UI) can inspect and edit it, then release it. Held exchanges surface via
/// `pendingBreakpoints()` (poll) or `pendingBreakpointStream()` (push) and are
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
    /// Fires the moment an exchange is parked, so a waiter doesn't have to poll
    /// `pendingBreakpoints()` in a loop to notice one. Unbuffered fan-out like
    /// `flowStream()`: a late subscriber misses prior holds, so subscribe *before*
    /// checking `pendingBreakpoints()` if a hold must not be missed.
    ///
    /// Holds are rare (each pins a live client connection) and short-lived, so
    /// consumers see a low-rate stream; it exists to make "arm → trigger → wait →
    /// resume" a wait rather than a poll.
    func pendingBreakpointStream() async -> AsyncStream<PendingBreakpoint>
    /// Release a held exchange: apply `edit` and continue, or `abort` to fail it
    /// with a 502. Throws `ProxyControlError.pendingBreakpointNotFound` if the id
    /// isn't held (already resumed or timed out).
    func resumeBreakpoint(pendingID: UUID, abort: Bool, edit: BreakpointEdit) async throws
}

public extension BreakpointControlling {
    /// Default for conformers that predate the push stream (an embedder driving the
    /// engine with its own control surface): no pushes, so a waiter falls back to
    /// the poll path rather than failing to compile.
    func pendingBreakpointStream() async -> AsyncStream<PendingBreakpoint> {
        AsyncStream { $0.finish() }
    }
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

public typealias ProxyControlling = FlowProviding & FlowReplaying & TLSInterceptControlling & CaptureControlling & RulesControlling & BreakpointControlling & AuditControlling & ClientCertificateControlling

/// Every requirement of `ProxyControlling`, enumerated as a value.
///
/// Why this exists: the engine's control surface has *two* consumers — the MCP
/// server (which reaches it directly, so the compiler keeps it complete) and the
/// human's TCA `ProxyClient` (a hand-written mirror, which the compiler does
/// **not** check). Nothing forced the mirror to keep up, and it didn't: an agent
/// could hold real traffic on a breakpoint with no way for the supervising human
/// to see or release it, because `ProxyClient` simply had no such field. That is
/// not a missing feature, it's a missing invariant — "AI operates, human
/// supervises" only holds if the human surface can reach what the AI can.
///
/// So: **adding a requirement to any of the protocols above means adding a case
/// here.** `ProxyClientParityTests` switches over `allCases` exhaustively, so a
/// new case fails to compile until it is either wired to a `ProxyClient`
/// endpoint or recorded as a deliberate omission *with a reason*. Silence is no
/// longer an option — the same trick `MCPToolExecutor.writeTools` uses to keep
/// audit coverage honest.
public enum ProxyCapability: String, CaseIterable, Sendable {
    // FlowProviding
    case status
    case recentFlows
    case recentFlowsMatching
    case recentFlowsForExport
    case flowByID
    case flowStream
    case connectedDevices
    case flowsClearedStream
    // FlowReplaying
    case replayByID
    case replayFlow
    // TLSInterceptControlling
    case certificateStatus
    case exportCACertificate
    case sslScope
    case setSSLScope
    // CaptureControlling
    case importFlows
    case setRecording
    case clearFlows
    // RulesControlling
    case rulesState
    case setRulesEnabled
    case addRule
    case updateRule
    case deleteRule
    case setRules
    case setGroupEnabled
    // BreakpointControlling
    case armBreakpoint
    case disarmBreakpoint
    case armedBreakpoints
    case pendingBreakpoints
    case pendingBreakpointStream
    case resumeBreakpoint
    // AuditControlling
    case recordAudit
    case recentAuditEntries
    case auditStream
    case clearAudit
    // ClientCertificateControlling
    case clientCertificates
    case setClientCertificate
    case deleteClientCertificate
}
