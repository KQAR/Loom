import Foundation
import LoomSharedModels

/// Reading captured traffic: recent flows, one flow in full, aggregate stats,
/// the shared filter vocabulary (`flowQuery`), the capture gate and the diff.
///
/// One filter vocabulary, parsed in one place, is deliberate — `get_recent_flows`
/// and `wait_for_flow` must not drift into subtly different notions of "matching".
extension MCPToolExecutor {
    func handleGetRecentFlows(_ arguments: [String: Any]) async throws -> String {
        let limit = (arguments["limit"] as? Int) ?? 20
        let query = try Self.flowQuery(from: arguments)
        let flows = await engine.recentFlows(matching: query, limit: limit)
        return prettyJSON(flows.map(Self.flowSummary))
    }

    func handleGetFlowDetail(_ arguments: [String: Any]) async throws -> String {
        guard let idString = arguments["id"] as? String, let id = UUID(uuidString: idString) else {
            throw MCPError.invalidParams("`id` must be a flow UUID string")
        }
        guard let flow = await engine.flow(id: id) else {
            throw MCPToolFailure("no flow with id \(idString)")
        }
        return prettyJSON(Self.flowDetail(
            flow,
            offset: max(0, (arguments["body_offset"] as? Int) ?? 0),
            maxBytes: max(1, (arguments["max_bytes"] as? Int) ?? Self.defaultBodyBytes),
            webSocketLimit: max(1, (arguments["ws_limit"] as? Int) ?? Self.defaultWebSocketMessages)
        ))
    }

    /// Upper bound on the flows one `get_stats` call aggregates. Set above the engine's
    /// in-memory ring capacity so it means "everything retained in memory" rather than
    /// a page — like `get_recent_flows`, the scan is over the ring, not the whole
    /// SQLite history.
    static let statsScanCap = 5_000

    func handleGetStats(_ arguments: [String: Any]) async throws -> String {
        let query = try Self.flowQuery(from: arguments)
        let grouping = try Self.grouping(from: arguments)
        let limit = (arguments["limit"] as? Int) ?? 10
        let slowest = (arguments["slowest"] as? Int) ?? 3

        let flows = await engine.recentFlows(matching: query, limit: Self.statsScanCap)
        let stats = FlowStats.compute(flows: flows, grouping: grouping, limit: limit, slowest: slowest)

        var payload: [String: Any] = [
            "groupBy": grouping.rawValue,
            "flowsConsidered": stats.total.flows,
            "total": Self.statsBucket(stats.total),
            "buckets": stats.buckets.map(Self.statsBucket),
            "bucketsOmitted": stats.bucketsOmitted,
            "slowest": stats.slowest.map { slow in
                var item: [String: Any] = ["id": slow.id.uuidString, "method": slow.method, "url": slow.url]
                if let statusCode = slow.statusCode { item["status"] = statusCode }
                if let ttfbMS = slow.ttfbMS { item["ttfbMS"] = ttfbMS }
                if let durationMS = slow.durationMS { item["durationMS"] = durationMS }
                return item
            },
        ]
        if let earliest = stats.earliest { payload["from"] = Self.iso8601.string(from: earliest) }
        if let latest = stats.latest { payload["to"] = Self.iso8601.string(from: latest) }
        return prettyJSON(payload)
    }

    static func statsBucket(_ bucket: FlowStats.Bucket) -> [String: Any] {
        var out: [String: Any] = [
            "key": bucket.key,
            "flows": bucket.flows,
            "errors": bucket.errors,
            // Rounded: three decimals is finer than any capture-sized sample justifies.
            "errorRate": (bucket.errorRate * 1000).rounded() / 1000,
            "statusClasses": bucket.statusClasses,
            "requestBytes": bucket.requestBytes,
            "responseBytes": bucket.responseBytes,
        ]
        if bucket.failed > 0 { out["failed"] = bucket.failed }
        if bucket.inFlight > 0 { out["inFlight"] = bucket.inFlight }
        if let ttfb = bucket.ttfb { out["ttfbMS"] = distribution(ttfb) }
        // Reported next to TTFB rather than left as durationMS - ttfbMS: telling
        // "the server is slow" from "the payload is big" is what this tool is for,
        // and a percentile of a difference is not the difference of percentiles.
        if let receive = bucket.receive { out["receiveMS"] = distribution(receive) }
        if let duration = bucket.duration { out["durationMS"] = distribution(duration) }
        // Only surfaced when it applies — but never omitted when it does, because it is
        // the difference between "this host sent 4 MB" and "at least 4 MB".
        if bucket.sizeUnknownFlows > 0 { out["sizeUnknownFlows"] = bucket.sizeUnknownFlows }
        return out
    }

    static func distribution(_ distribution: FlowStats.Distribution) -> [String: Any] {
        ["p50": distribution.p50, "p95": distribution.p95, "max": distribution.max, "samples": distribution.samples]
    }

    static func grouping(from arguments: [String: Any]) throws -> FlowGrouping {
        guard let raw = arguments["group_by"] else { return .host }
        guard let text = raw as? String, let grouping = FlowGrouping(rawValue: text.lowercased()) else {
            throw MCPError.invalidParams(
                "`group_by` must be one of: \(FlowGrouping.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }
        return grouping
    }

    /// Parse the `get_recent_flows` filter arguments. Malformed input is rejected
    /// rather than silently ignored: a filter that quietly doesn't apply would hand
    /// an agent unfiltered traffic it believes is filtered — worse than an error.
    /// Parse a side selector, rejecting an unknown value rather than silently
    /// widening to "both" — a typo that quietly searches the other half too would
    /// return the exact noise the selector exists to remove.
    static func exchangeSide(_ raw: Any?, key: String) throws -> ExchangeSide {
        guard let raw else { return .any }
        guard let text = raw as? String, let side = ExchangeSide(rawValue: text) else {
            throw MCPError.invalidParams("`\(key)` must be one of \"any\", \"request\", \"response\"")
        }
        return side
    }

    static func flowQuery(from arguments: [String: Any]) throws -> FlowQuery {
        var query = FlowQuery()
        query.host = arguments["host"] as? String
        query.urlContains = arguments["url_contains"] as? String
        query.deviceIP = arguments["device_ip"] as? String
        query.sourceApp = arguments["source_app"] as? String
        query.headerContains = arguments["header_contains"] as? String
        query.headerSide = try Self.exchangeSide(arguments["header_in"], key: "header_in")
        query.bodyContains = arguments["body_contains"] as? String
        query.bodySide = try Self.exchangeSide(arguments["body_in"], key: "body_in")
        query.onlyErrors = (arguments["only_errors"] as? Bool) ?? false

        switch arguments["method"] {
        case let single as String: query.methods = [single]
        case let many as [String]: query.methods = many
        case nil: break
        default: throw MCPError.invalidParams("`method` must be a string or an array of strings")
        }

        query.statusMin = arguments["status_min"] as? Int
        query.statusMax = arguments["status_max"] as? Int
        switch arguments["status"] {
        case let exact as Int:
            query.statusMin = exact
            query.statusMax = exact
        case let text as String:
            guard let range = Self.statusClass(text) else {
                throw MCPError.invalidParams("`status` must be a number (500) or a class like \"5xx\"")
            }
            query.statusMin = range.lowerBound
            query.statusMax = range.upperBound
        case nil: break
        default: throw MCPError.invalidParams("`status` must be a number or a string like \"5xx\"")
        }

        if let seconds = arguments["since_seconds"] as? Double {
            query.since = Date().addingTimeInterval(-abs(seconds))
        } else if let seconds = arguments["since_seconds"] as? Int {
            query.since = Date().addingTimeInterval(-abs(Double(seconds)))
        }
        if let raw = arguments["since"] as? String {
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

    func handleSetRecording(_ arguments: [String: Any]) async throws -> String {
        guard let recording = arguments["recording"] as? Bool else {
            throw MCPError.invalidParams("`recording` must be a boolean")
        }
        await engine.setRecording(recording)
        return prettyJSON(["isRecording": recording])
    }

    /// Destructive: wipes the ring and the durable store. Audited like every write,
    /// and the engine broadcasts the clear so the human's window empties too rather
    /// than showing flows that no longer exist.
    func handleClearFlows(_ arguments: [String: Any]) async throws -> String {
        let before = await engine.status().capturedCount
        await engine.clearFlows()
        return prettyJSON(["cleared": before])
    }

    func handleDiffFlows(_ arguments: [String: Any]) async throws -> String {
        guard let baseString = arguments["base"] as? String, let baseID = UUID(uuidString: baseString) else {
            throw MCPError.invalidParams("`base` must be a flow UUID string")
        }
        guard let baseFlow = await engine.flow(id: baseID) else {
            throw MCPToolFailure("no flow with id \(baseString)")
        }

        // Resolve the two sides. Explicit `compared` wins; otherwise diff a replay
        // against the flow it was replayed from (base = original, compared = replay),
        // which is the natural one-argument "how did my replay change things" call.
        let base: Flow
        let compared: Flow
        if let comparedString = arguments["compared"] as? String {
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
                throw MCPToolFailure("flow \(baseString) was not replayed from another flow — pass `compared` explicitly")
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
