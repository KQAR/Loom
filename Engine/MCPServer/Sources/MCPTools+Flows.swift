import Foundation
import LoomSharedModels

/// Reading captured traffic: recent flows, one flow in full, aggregate stats,
/// the shared filter vocabulary (`flowQuery`), the capture gate and the diff.
///
/// One filter vocabulary, parsed in one place, is deliberate — `get_recent_flows`
/// and `wait_for_flow` must not drift into subtly different notions of "matching".
extension MCPToolExecutor {
    func handleGetRecentFlows(_ arguments: MCPArguments) async throws -> String {
        let limit = try arguments.int("limit", or: 20)
        let query = try Self.flowQuery(from: arguments)
        let flows = await engine.recentFlows(matching: query, limit: limit)
        return prettyJSON(flows.map(Self.flowSummary))
    }

    func handleGetFlowDetail(_ arguments: MCPArguments) async throws -> String {
        let id = try arguments.requiredUUID("id", "a flow UUID string")
        guard let flow = await engine.flow(id: id) else {
            throw MCPToolFailure("no flow with id \(id.uuidString)")
        }
        return prettyJSON(Self.flowDetail(
            flow,
            offset: max(0, try arguments.int("body_offset", or: 0)),
            maxBytes: max(1, try arguments.int("max_bytes", or: Self.defaultBodyBytes)),
            webSocketLimit: max(1, try arguments.int("ws_limit", or: Self.defaultWebSocketMessages))
        ))
    }

    /// Upper bound on the flows one `get_stats` call aggregates. Set above the engine's
    /// in-memory ring capacity so it means "everything retained" rather than a page —
    /// and since the filtered read now falls through to the durable store, that phrase
    /// finally covers history too, not just the ring.
    static let statsScanCap = 5_000

    func handleGetStats(_ arguments: MCPArguments) async throws -> String {
        let query = try Self.flowQuery(from: arguments)
        let grouping = try Self.grouping(from: arguments)
        let limit = try arguments.int("limit", or: 10)
        let slowest = try arguments.int("slowest", or: 3)

        let result = await engine.searchFlows(matching: query, limit: Self.statsScanCap)
        let stats = FlowStats.compute(flows: result.flows, grouping: grouping, limit: limit, slowest: slowest)

        var payload: [String: Any] = [
            "groupBy": grouping.rawValue,
            "flowsConsidered": stats.total.flows,
            "total": Self.statsBucket(stats.total),
            "buckets": stats.buckets.map(Self.statsBucket),
            "bucketsOmitted": stats.bucketsOmitted,
            "slowest": MCPRender.array(stats.slowest.map(SlowestFlowRender.init)),
        ]
        // What the sample is drawn from, so `flowsConsidered` can be read against a
        // denominator rather than guessed at. Percentiles over a fraction of the
        // matching traffic are still percentiles of *something*, which is exactly how
        // a partial answer gets mistaken for the answer.
        if let retained = result.storedFlowCount { payload["flowsRetained"] = retained }
        // Only ever present when true — a `false` here would add a key that was never
        // there and imply the question is usually worth asking.
        if result.budgetExhausted { payload["historyScanTruncated"] = true }
        if let earliest = stats.earliest { payload["from"] = Self.iso8601.string(from: earliest) }
        if let latest = stats.latest { payload["to"] = Self.iso8601.string(from: latest) }
        return prettyJSON(payload)
    }

    static func statsBucket(_ bucket: FlowStats.Bucket) -> [String: Any] {
        MCPRender.dict(StatsBucketRender(bucket))
    }

    static func grouping(from arguments: MCPArguments) throws -> FlowGrouping {
        try arguments.option("group_by", or: .host)
    }

    /// Parse the `get_recent_flows` filter arguments. Malformed input is rejected
    /// rather than silently ignored: a filter that quietly doesn't apply would hand
    /// an agent unfiltered traffic it believes is filtered — worse than an error.
    /// Parse a side selector, rejecting an unknown value rather than silently
    /// widening to "both" — a typo that quietly searches the other half too would
    /// return the exact noise the selector exists to remove.
    static func flowQuery(from arguments: MCPArguments) throws -> FlowQuery {
        var query = FlowQuery()
        query.host = try arguments.string("host")
        query.urlContains = try arguments.string("url_contains")
        query.deviceIP = try arguments.string("device_ip")
        query.sourceApp = try arguments.string("source_app")
        query.headerContains = try arguments.string("header_contains")
        query.headerSide = try arguments.option("header_in", or: .any)
        query.bodyContains = try arguments.string("body_contains")
        query.bodySide = try arguments.option("body_in", or: .any)
        query.onlyErrors = try arguments.bool("only_errors", or: false)

        // `method` and `status` are the two `oneOf` arguments, so they are the two
        // read as values rather than through a typed accessor — the shape *is* the
        // vocabulary here, and collapsing either to one type would drop a spelling
        // the schema advertises.
        switch arguments.value("method") {
        case let .string(single): query.methods = [single]
        case .array: query.methods = try arguments.stringArray("method")
        case nil: break
        default: throw MCPError.invalidParams("`method` must be a string or an array of strings")
        }

        query.statusMin = try arguments.int("status_min")
        query.statusMax = try arguments.int("status_max")
        switch arguments.value("status") {
        case .int, .double:
            let exact = try arguments.int("status")
            query.statusMin = exact
            query.statusMax = exact
        case let .string(text):
            guard let range = Self.statusClass(text) else {
                throw MCPError.invalidParams("`status` must be a number (500) or a class like \"5xx\"")
            }
            query.statusMin = range.lowerBound
            query.statusMax = range.upperBound
        case nil: break
        default: throw MCPError.invalidParams("`status` must be a number or a string like \"5xx\"")
        }

        if let seconds = try arguments.double("since_seconds") {
            query.since = Date().addingTimeInterval(-abs(seconds))
        }
        if let raw = try arguments.string("since") {
            guard let date = Self.iso8601.date(from: raw) ?? Self.iso8601Fractional.date(from: raw) else {
                throw MCPError.invalidParams("`since` must be an ISO-8601 timestamp")
            }
            query.since = date
        }
        return query
    }

    /// `"5xx"` → 500...599. Accepts any single leading digit; anything else is nil.
    static func statusClass(_ text: String) -> ClosedRange<Int>? {
        let lowered = text.lowercased()
        guard lowered.count == 3, lowered.hasSuffix("xx"),
              let digit = lowered.first?.wholeNumberValue, (1 ... 5).contains(digit)
        else { return nil }
        return (digit * 100) ... (digit * 100 + 99)
    }

    func handleSetRecording(_ arguments: MCPArguments) async throws -> String {
        let recording = try arguments.requiredBool("recording")
        await engine.setRecording(recording)
        return prettyJSON(["isRecording": recording])
    }

    /// Destructive: wipes the ring and the durable store. Audited like every write,
    /// and the engine broadcasts the clear so the human's window empties too rather
    /// than showing flows that no longer exist.
    func handleClearFlows(_ arguments: MCPArguments) async throws -> String {
        let before = await engine.status().capturedCount
        await engine.clearFlows()
        return prettyJSON(["cleared": before])
    }

    func handleDiffFlows(_ arguments: MCPArguments) async throws -> String {
        let baseID = try arguments.requiredUUID("base", "a flow UUID string")
        guard let baseFlow = await engine.flow(id: baseID) else {
            throw MCPToolFailure("no flow with id \(baseID.uuidString)")
        }

        // Resolve the two sides. Explicit `compared` wins; otherwise diff a replay
        // against the flow it was replayed from (base = original, compared = replay),
        // which is the natural one-argument "how did my replay change things" call.
        let base: Flow
        let compared: Flow
        if let comparedString = try arguments.string("compared") {
            guard let comparedID = UUID(uuidString: comparedString) else {
                throw MCPError.invalidParams("`compared` must be a flow UUID string")
            }
            guard let comparedFlow = await engine.flow(id: comparedID) else {
                throw MCPToolFailure("no flow with id \(comparedString)")
            }
            base = baseFlow
            compared = comparedFlow
        } else {
            guard let originalID = baseFlow.replayedFrom else {
                throw MCPToolFailure("flow \(baseID.uuidString) was not replayed from another flow — pass `compared` explicitly")
            }
            guard let original = await engine.flow(id: originalID) else {
                throw MCPToolFailure("original flow \(originalID.uuidString) (replayedFrom) is no longer in the store — pass `compared` explicitly")
            }
            base = original
            compared = baseFlow
        }

        return prettyJSON(FlowDiff.diff(base: base, compared: compared))
    }
}
