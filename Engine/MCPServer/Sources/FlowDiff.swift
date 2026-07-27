import Foundation
import LoomSharedModels

/// JSON rendering of a `FlowComparison` for the `diff_flows` tool.
///
/// The comparison **semantics** live in `FlowComparison` (SharedModels), because
/// the Inspector's diff pane renders the same value — an agent and the human
/// supervising it must not be shown two different answers to "what did the replay
/// change". This file is only the wire shape: which keys, which nesting, what an
/// absent value looks like. Keep it that way; a rule about *what counts as a
/// difference* belongs next to the model, not here.
enum FlowDiff {
    /// Diff `compared` against `base`, rendered as the tool's JSON object. Only
    /// the parts that actually differ appear; `identical` is true when nothing did.
    static func diff(base: Flow, compared: Flow) -> [String: Any] {
        render(FlowComparison.compare(base: base, compared: compared))
    }

    static func render(_ comparison: FlowComparison) -> [String: Any] {
        var out: [String: Any] = [
            "baseId": comparison.baseID.uuidString,
            "comparedId": comparison.comparedID.uuidString,
        ]
        let request = render(request: comparison.request)
        let response = render(response: comparison.response)
        if !request.isEmpty { out["request"] = request }
        if !response.isEmpty { out["response"] = response }
        if let error = comparison.error { out["error"] = render(change: error) }
        out["identical"] = comparison.isIdentical
        return out
    }

    // MARK: - Request / response

    private static func render(request: FlowComparison.MessageComparison) -> [String: Any] {
        var out: [String: Any] = [:]
        if let method = request.method { out["method"] = render(change: method) }
        if let url = request.url { out["url"] = render(change: url) }
        let headers = render(headers: request.headers)
        if !headers.isEmpty { out["headers"] = headers }
        if let body = request.body { out["body"] = render(body: body) }
        return out
    }

    private static func render(response: FlowComparison.ResponseComparison) -> [String: Any] {
        if let presence = response.presence {
            // One side has a response and the other doesn't.
            return ["present": ["base": presence.base ?? false, "compared": presence.compared ?? false]]
        }
        var out: [String: Any] = [:]
        if let status = response.status { out["status"] = render(change: status) }
        if let version = response.httpVersion { out["httpVersion"] = render(change: version) }
        let headers = render(headers: response.headers)
        if !headers.isEmpty { out["headers"] = headers }
        if let body = response.body { out["body"] = render(body: body) }
        return out
    }

    // MARK: - Leaves

    /// `{base, compared}`, with a missing side as JSON null so an added/removed
    /// scalar stays legible.
    private static func render<Value>(change: FlowComparison.ValueChange<Value>) -> [String: Any] {
        ["base": change.base as Any? ?? NSNull(), "compared": change.compared as Any? ?? NSNull()]
    }

    /// Header changes grouped into `added` / `removed` / `changed` — the shape the
    /// tool has always emitted, kept stable for existing agent prompts.
    private static func render(headers: [FlowComparison.HeaderChange]) -> [String: Any] {
        var added: [[String: Any]] = []
        var removed: [[String: Any]] = []
        var changed: [[String: Any]] = []
        for header in headers {
            switch (header.base, header.compared) {
            case let (nil, compared?):
                added.append(["name": header.name, "values": compared])
            case let (base?, nil):
                removed.append(["name": header.name, "values": base])
            case let (base?, compared?):
                changed.append(["name": header.name, "base": base, "compared": compared])
            case (nil, nil):
                break // not representable: a change with neither side
            }
        }
        var out: [String: Any] = [:]
        if !added.isEmpty { out["added"] = added }
        if !removed.isEmpty { out["removed"] = removed }
        if !changed.isEmpty { out["changed"] = changed }
        return out
    }

    private static func render(body: FlowComparison.BodyComparison) -> [String: Any] {
        var out: [String: Any] = [
            "baseBytes": body.baseBytes,
            "comparedBytes": body.comparedBytes,
        ]
        switch body.detail {
        case .binary:
            out["binary"] = true
        case let .tooLarge(baseLines, comparedLines, limit):
            out["lineDiffSkipped"] = "body exceeds \(limit) lines"
            out["baseLines"] = baseLines
            out["comparedLines"] = comparedLines
        case let .lines(added, removed):
            if !added.isEmpty { out["addedLines"] = added }
            if !removed.isEmpty { out["removedLines"] = removed }
        }
        return out
    }

    // MARK: - Test seams
    //
    // The unit tests exercise the two pieces most likely to regress silently
    // (header grouping and the body/line diff) through these, so they keep
    // testing the shipped semantics now that those live in SharedModels.

    static func headerDiff(_ base: [HeaderPair], _ compared: [HeaderPair]) -> [String: Any] {
        render(headers: FlowComparison.compareHeaders(base, compared))
    }

    static func bodyDiff(_ base: Data?, _ compared: Data?) -> [String: Any] {
        FlowComparison.compareBodies(base, compared).map(render(body:)) ?? [:]
    }

    static func lineDiff(_ a: [String], _ b: [String]) -> (added: [String], removed: [String]) {
        FlowComparison.lineDiff(a, b)
    }
}
