import Foundation
import LoomSharedModels

/// `replay_flow` — the write tool that makes Loom AI-*operable* rather than
/// merely AI-readable, including the batch form (N copies at a bounded
/// concurrency, for "is this flaky or is it broken").
extension MCPToolExecutor {
    /// Hard caps on one batch replay. These are real requests to a real upstream, so
    /// the ceiling is deliberately low, and asking for more is an error rather than a
    /// silent clamp — a caller sizing a repro ("did it fail 3 times in 200?") must not
    /// be handed 50 and told nothing.
    static let maxReplayCount = 50

    static let maxReplayConcurrency = 10

    func handleReplayFlow(_ arguments: MCPArguments) async throws -> String {
        let id = try arguments.requiredUUID("id", "a flow UUID string")
        let overrides = try Self.overrides(from: arguments)
        let count = try Self.boundedInt(arguments, "count", default: 1, max: Self.maxReplayCount)
        let concurrency = try Self.boundedInt(
            arguments, "concurrency", default: 1, max: Self.maxReplayConcurrency
        )

        // One replay keeps the single-flow shape it has always had — the common case
        // shouldn't pay for batch scaffolding, in tokens or in reading effort.
        // A replacement body that was meant to be JSON and isn't still gets sent —
        // that's a legitimate thing to replay — but it comes back said out loud.
        let warnings = Self.bodyWarnings(fromArguments: arguments)

        guard count > 1 else {
            do {
                let flow = try await engine.replay(id: id, overrides: overrides)
                var payload = Self.flowDetail(flow)
                Self.attach(warnings: warnings, to: &payload)
                return prettyJSON(payload)
            } catch let error as ProxyControlError {
                throw MCPToolFailure(error.message)
            }
        }
        return await batchReplay(
            id: id, overrides: overrides, count: count, concurrency: concurrency, warnings: warnings
        )
    }

    /// Send the same request `count` times with at most `concurrency` in flight.
    ///
    /// A failure is data, not a thrown error: the point of replaying 20 times is to
    /// learn that 3 of them failed, which a call that gives up on the first failure
    /// can't tell you. Each attempt still records its own flow in the store (the
    /// engine does that even for a failed replay), so the batch summary is a summary,
    /// not the only record.
    func batchReplay(
        id: UUID, overrides: ReplayOverrides, count: Int, concurrency: Int, warnings: [String] = []
    ) async -> String {
        let engine = self.engine
        var flows: [Flow] = []
        var failures: [String] = []

        await withTaskGroup(of: Result<Flow, Error>.self) { group in
            var launched = 0
            func launch() {
                group.addTask {
                    do { return .success(try await engine.replay(id: id, overrides: overrides)) }
                    catch { return .failure(error) }
                }
                launched += 1
            }
            // Keep the window full rather than running in lockstep rounds: with
            // concurrency 4 and count 20, a slow attempt holds up one slot, not five.
            for _ in 0 ..< min(concurrency, count) { launch() }
            while let result = await group.next() {
                switch result {
                case let .success(flow): flows.append(flow)
                case let .failure(error):
                    failures.append((error as? ProxyControlError)?.message ?? error.localizedDescription)
                }
                if launched < count { launch() }
            }
        }

        // Attempts finish out of order; report them in the order they were sent.
        flows.sort { $0.startedAt < $1.startedAt }
        let stats = FlowStats.compute(flows: flows, grouping: .none, slowest: 0)
        var payload: [String: Any] = [
            "requested": count,
            "concurrency": concurrency,
            "succeeded": flows.count,
            "failed": failures.count,
            "statusClasses": stats.total.statusClasses,
            "replays": MCPRender.array(flows.map(ReplayAttemptRender.init)),
        ]
        if let ttfb = stats.total.ttfb { payload["ttfbMS"] = MCPRender.dict(DistributionRender(ttfb)) }
        if let duration = stats.total.duration { payload["durationMS"] = MCPRender.dict(DistributionRender(duration)) }
        // Distinct messages with counts: 20 copies of "connection refused" is one fact.
        if !failures.isEmpty {
            payload["errors"] = Dictionary(grouping: failures, by: { $0 }).map { message, occurrences in
                ["message": message, "count": occurrences.count] as [String: Any]
            }
        }
        Self.attach(warnings: warnings, to: &payload)
        return prettyJSON(payload)
    }

    /// A positive integer argument with a documented ceiling. Absent → `default`;
    /// present but out of range → an error naming the ceiling.
    static func boundedInt(
        _ arguments: MCPArguments, _ field: String, default fallback: Int, max ceiling: Int
    ) throws -> Int {
        guard let value = try arguments.int(field) else { return fallback }
        guard value >= 1 else { throw MCPError.invalidParams("`\(field)` must be at least 1") }
        guard value <= ceiling else {
            throw MCPError.invalidParams("`\(field)` must be at most \(ceiling) (asked for \(value))")
        }
        return value
    }

    static func overrides(from arguments: MCPArguments) throws -> ReplayOverrides {
        ReplayOverrides(
            method: try arguments.string("method"),
            url: try arguments.string("url"),
            setHeaders: try Self.headerPairs(from: arguments),
            removeHeaders: try arguments.stringArray("remove_headers"),
            body: try Self.bodyOverride(from: arguments)
        )
    }

    /// The `set_headers` free-form map as ordered pairs. Shared with `resume`, which
    /// takes the same three body/header arguments — two copies of "how a header edit
    /// is spelled" is how the two write paths drift.
    static func headerPairs(from arguments: MCPArguments) throws -> [HeaderPair]? {
        try arguments.stringMap("set_headers")?.map { HeaderPair(name: $0.key, value: $0.value) }
    }

    /// `body` replaces, `clear_body` empties, neither leaves the captured body alone.
    /// `body` wins, as its description says.
    static func bodyOverride(from arguments: MCPArguments) throws -> BodyOverride {
        if let text = try arguments.string("body") { return .replace(Data(text.utf8)) }
        if try arguments.bool("clear_body", or: false) { return .clear }
        return .keep
    }
}
