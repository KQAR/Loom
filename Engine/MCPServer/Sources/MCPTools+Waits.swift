import Foundation
import LoomSharedModels

/// Shared accumulator for the blocking `wait_*` tools, so a collection in progress
/// is readable after the deadline cancels the task that was filling it.
private actor WaitCollector<Item: Sendable> {
    private var items: [Item] = []
    private var seen: Set<UUID> = []

    /// Append unless this id was already collected; returns the running count.
    func add(_ item: Item, id: UUID) -> Int {
        if seen.insert(id).inserted { items.append(item) }
        return items.count
    }

    var collected: [Item] { items }
}

/// The blocking tools: `wait_for_flow` and `wait_for_pending`.
///
/// They exist so an agent stops poll-looping (`get_recent_flows` in a `while`),
/// which burns turns and adds latency to every debug loop. Both share one
/// accumulator so a collection in progress survives the deadline that cancels
/// the task filling it, and one deadline policy — see `maxWaitSeconds` for why
/// the cap is the client's rather than ours.
extension MCPToolExecutor {
    /// Default / hard cap for `wait_for_flow` and `wait_for_pending`.
    ///
    /// The cap is the client's, not ours: Claude Code gives an HTTP MCP server 60 s
    /// to produce the first response byte unless the server entry raises it (the
    /// plugin's `.mcp.json` sets `timeout: 120000`, and the bridge sets its own
    /// request timeout), and aborts a call that goes 5 minutes without a byte. 60 s
    /// therefore stays inside the *unconfigured* limit, so a wait can't fail as a
    /// transport error on a client that never read our config.
    static let defaultWaitSeconds: Double = 20

    static let maxWaitSeconds: Double = 60

    /// How far back a `wait_for_flow` with no explicit window looks.
    ///
    /// Not zero, and that matters. The natural sequence is *trigger the action, then
    /// call the tool* — so by the time the call lands, the request it is waiting for
    /// may already have been captured. A strict "from now on" window would report a
    /// timeout for traffic sitting in the store, which is the exact failure the tool
    /// exists to remove. A few seconds of grace covers the gap without dragging in
    /// traffic from earlier in the session (which is what `get_recent_flows` is for).
    static let defaultWaitLookback: Double = 10

    /// How much of an exchange `wait_for_flow` waits for.
    enum WaitUntil: String {
        /// The request has been seen; nothing is known about the response yet.
        case request
        /// The status line is known (streaming, completed or failed).
        case response
        /// Terminal: completed or failed, so bodies and timing are final.
        case completed

        func isSatisfied(by flow: Flow) -> Bool {
            switch self {
            case .request:
                return true
            case .response:
                return flow.statusCode != nil || flow.error != nil
            case .completed:
                return flow.completedAt != nil || flow.error != nil
            }
        }
    }

    /// Wait for traffic instead of polling for it.
    ///
    /// Two properties make this safe to rely on, and both come from the ordering
    /// here rather than from anything the caller does:
    ///
    /// 1. **No gap between looking and listening.** The stream is subscribed
    ///    *before* the store is read, so a flow arriving in between is delivered on
    ///    the stream rather than falling into the hole a check-then-subscribe order
    ///    would leave.
    /// 2. **A timeout costs nothing.** The match is a query over the retained
    ///    capture, not the consumption of an event: whatever this call misses is
    ///    still in the store for the next one. So a client-side abort, or the
    ///    caller's own `max_seconds`, degrades to polling — never to lost traffic.
    ///    `waitStartedAt` comes back so a retry can resume from exactly here.
    func handleWaitForFlow(_ arguments: [String: Any]) async throws -> String {
        let seconds = try Self.waitSeconds(from: arguments)
        let limit = max(1, (arguments["limit"] as? Int) ?? 1)
        let until = try Self.waitUntil(from: arguments)
        var query = try Self.flowQuery(from: arguments)
        let startedWaitingAt = Date()
        // A wait needs *some* window: inheriting `get_recent_flows`' match-everything
        // default would return the oldest retained flow instantly, which is never what
        // "wait for the request I'm about to trigger" means. See `defaultWaitLookback`
        // for why the default window starts slightly in the past rather than at `now`.
        if query.since == nil {
            query.since = startedWaitingAt.addingTimeInterval(-Self.defaultWaitLookback)
        }
        let windowFrom = query.since ?? startedWaitingAt

        let stream = await engine.flowStream()
        let existing = await engine.recentFlows(matching: query, limit: limit)
            .filter { until.isSatisfied(by: $0) }
        if !existing.isEmpty {
            // The store hands back newest-first; a wait reads better oldest-first
            // (the order the exchanges actually happened in).
            return waitResult(
                matched: Array(existing.reversed()), timedOut: false,
                startedWaitingAt: startedWaitingAt, windowFrom: windowFrom
            )
        }

        let matched = await Self.waitCollecting(
            from: stream, id: \.id, seconds: seconds, limit: limit,
            accepts: { until.isSatisfied(by: $0) && query.matches($0) }
        )
        return waitResult(
            matched: matched, timedOut: matched.count < limit,
            startedWaitingAt: startedWaitingAt, windowFrom: windowFrom
        )
    }

    func waitResult(
        matched: [Flow], timedOut: Bool, startedWaitingAt: Date, windowFrom: Date
    ) -> String {
        prettyJSON([
            "matched": matched.map(Self.flowSummary),
            "timedOut": timedOut,
            "waitedMS": Int(Date().timeIntervalSince(startedWaitingAt) * 1000),
            // The retry cursor: the start of the window this call considered. Passing
            // it back as `since` on a follow-up call makes the retry gapless, which is
            // what keeps a timeout (ours or the transport's) harmless.
            "windowFrom": Self.iso8601.string(from: windowFrom),
        ])
    }

    /// Wait for a breakpoint to hold an exchange. Same subscribe-then-check ordering
    /// as `wait_for_flow`, for the same reason — except a hold is *not* retained
    /// state: it is a live connection that auto-proceeds when the engine's hold
    /// timeout expires, so a missed notification really would be a missed exchange.
    func handleWaitForPending(_ arguments: [String: Any]) async throws -> String {
        let seconds = try Self.waitSeconds(from: arguments)
        let limit = max(1, (arguments["limit"] as? Int) ?? 1)
        let breakpointID = try Self.optionalUUID(arguments["breakpoint_id"], field: "breakpoint_id")
        let startedWaitingAt = Date()

        let accepts: @Sendable (PendingBreakpoint) -> Bool = { pending in
            breakpointID == nil || pending.breakpointID == breakpointID
        }

        let stream = await engine.pendingBreakpointStream()
        let alreadyHeld = await engine.pendingBreakpoints().filter(accepts)
        if !alreadyHeld.isEmpty {
            return pendingWaitResult(alreadyHeld, timedOut: false, startedWaitingAt: startedWaitingAt)
        }

        let held = await Self.waitCollecting(
            from: stream, id: \.id, seconds: seconds, limit: limit, accepts: accepts
        )
        return pendingWaitResult(held, timedOut: held.count < limit, startedWaitingAt: startedWaitingAt)
    }

    func pendingWaitResult(
        _ pending: [PendingBreakpoint], timedOut: Bool, startedWaitingAt: Date
    ) -> String {
        prettyJSON([
            "pending": pending.map(Self.pendingBreakpoint),
            "timedOut": timedOut,
            "waitedMS": Int(Date().timeIntervalSince(startedWaitingAt) * 1000),
        ])
    }

    /// Accumulate accepted items off `stream` until `limit` is reached or `seconds`
    /// elapse, whichever comes first.
    ///
    /// Partial results survive the deadline — the collector is shared state, not the
    /// racing task's return value, so a wait for 3 flows that saw 2 reports those 2
    /// instead of pretending it saw nothing. Deduplicated by id because a flow is
    /// emitted several times as it progresses (pending → streaming → completed), and
    /// `until: request` would otherwise count one exchange repeatedly.
    static func waitCollecting<Item: Sendable>(
        from stream: AsyncStream<Item>,
        id: @escaping @Sendable (Item) -> UUID,
        seconds: Double,
        limit: Int,
        accepts: @escaping @Sendable (Item) -> Bool
    ) async -> [Item] {
        let collector = WaitCollector<Item>()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await item in stream where accepts(item) {
                    if await collector.add(item, id: id(item)) >= limit { break }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            // Whichever finishes first — a full collection or the deadline — ends the
            // wait; cancelling the group tears down the other. Cancellation of the
            // *calling* task (the MCP client hung up mid-call) lands here too, so a
            // dropped connection doesn't leave a waiter parked for the full duration.
            await group.next()
            group.cancelAll()
        }
        return await collector.collected
    }

    static func waitSeconds(from arguments: [String: Any]) throws -> Double {
        let raw: Double
        switch arguments["max_seconds"] {
        case let value as Double: raw = value
        case let value as Int: raw = Double(value)
        case nil: return defaultWaitSeconds
        default: throw MCPError.invalidParams("`max_seconds` must be a number")
        }
        guard raw > 0 else { throw MCPError.invalidParams("`max_seconds` must be greater than 0") }
        // Clamped rather than rejected: a client asking for a longer wait than the
        // MCP transport will tolerate gets the longest safe one, not an error.
        return min(raw, maxWaitSeconds)
    }

    /// An optional UUID argument. A present-but-malformed value is an error, never a
    /// silently ignored filter.
    static func optionalUUID(_ raw: Any?, field: String) throws -> UUID? {
        guard let raw else { return nil }
        guard let text = raw as? String, let id = UUID(uuidString: text) else {
            throw MCPError.invalidParams("`\(field)` must be a UUID string")
        }
        return id
    }

    static func waitUntil(from arguments: [String: Any]) throws -> WaitUntil {
        guard let raw = arguments["until"] else { return .completed }
        guard let text = raw as? String, let until = WaitUntil(rawValue: text.lowercased()) else {
            throw MCPError.invalidParams("`until` must be one of: completed, response, request")
        }
        return until
    }
}
