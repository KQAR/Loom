import Foundation
import LoomSharedModels

/// Pure, transport-free diff between two captured flows — the "observe" step of
/// Loom's capture → modify → replay → **diff** loop. Given a baseline flow and a
/// changed one (typically a replay and its original), it reports exactly what the
/// change did to the request and response: method/url, header add/remove/change,
/// status, and a line-level body diff for text payloads. Output is a JSON-ready
/// `[String: Any]` so `MCPToolExecutor` renders it verbatim; keeping the logic
/// here (not inlined in the tool) makes it unit-testable without NIO.
enum FlowDiff {
    /// Diff `compared` against `base`. Only the parts that actually differ appear
    /// in the result; `identical` is true when nothing changed.
    static func diff(base: Flow, compared: Flow) -> [String: Any] {
        var out: [String: Any] = [
            "baseId": base.id.uuidString,
            "comparedId": compared.id.uuidString,
        ]

        let requestDiff = requestDiff(base.request, compared.request)
        let responseDiff = responseDiff(base.response, compared.response)
        let errorDiff = scalarDiff(base.error, compared.error)

        if !requestDiff.isEmpty { out["request"] = requestDiff }
        if !responseDiff.isEmpty { out["response"] = responseDiff }
        if let errorDiff { out["error"] = errorDiff }

        out["identical"] = requestDiff.isEmpty && responseDiff.isEmpty && errorDiff == nil
        return out
    }

    // MARK: - Request / response

    private static func requestDiff(_ base: CapturedRequest, _ compared: CapturedRequest) -> [String: Any] {
        var out: [String: Any] = [:]
        if let method = scalarDiff(base.method, compared.method) { out["method"] = method }
        if let url = scalarDiff(base.url, compared.url) { out["url"] = url }
        let headers = headerDiff(base.headers, compared.headers)
        if !headers.isEmpty { out["headers"] = headers }
        let body = bodyDiff(base.body, compared.body)
        if !body.isEmpty { out["body"] = body }
        return out
    }

    private static func responseDiff(_ base: CapturedResponse?, _ compared: CapturedResponse?) -> [String: Any] {
        switch (base, compared) {
        case (nil, nil):
            return [:]
        case let (base?, compared?):
            var out: [String: Any] = [:]
            if let status = scalarDiff(base.statusCode, compared.statusCode) { out["status"] = status }
            if let version = scalarDiff(base.httpVersion, compared.httpVersion) { out["httpVersion"] = version }
            let headers = headerDiff(base.headers, compared.headers)
            if !headers.isEmpty { out["headers"] = headers }
            let body = bodyDiff(base.body, compared.body)
            if !body.isEmpty { out["body"] = body }
            return out
        default:
            // One side has a response and the other doesn't.
            return ["present": ["base": base != nil, "compared": compared != nil]]
        }
    }

    // MARK: - Scalars

    /// `{base, compared}` when the two values differ, else nil. `nil` maps to
    /// JSON null so an added/removed scalar is still legible.
    private static func scalarDiff<T: Equatable>(_ base: T?, _ compared: T?) -> [String: Any]? {
        guard base != compared else { return nil }
        return ["base": base as Any? ?? NSNull(), "compared": compared as Any? ?? NSNull()]
    }

    // MARK: - Headers

    /// Diff two ordered header lists grouped by (case-insensitive) name:
    /// `added` (name only in compared), `removed` (only in base), `changed`
    /// (name in both but the value list differs). Repeated headers are kept as a
    /// value list so a duplicated/dropped header shows up.
    static func headerDiff(_ base: [HeaderPair], _ compared: [HeaderPair]) -> [String: Any] {
        // Preserve first-seen display casing while keying case-insensitively.
        func grouped(_ headers: [HeaderPair]) -> (order: [String], byKey: [String: (name: String, values: [String])]) {
            var order: [String] = []
            var byKey: [String: (name: String, values: [String])] = [:]
            for header in headers {
                let key = header.name.lowercased()
                if byKey[key] == nil {
                    byKey[key] = (header.name, [])
                    order.append(key)
                }
                byKey[key]?.values.append(header.value)
            }
            return (order, byKey)
        }

        let b = grouped(base)
        let c = grouped(compared)

        var added: [[String: Any]] = []
        var removed: [[String: Any]] = []
        var changed: [[String: Any]] = []

        // Union of keys, base order first then compared-only keys, for stable output.
        var seen = Set<String>()
        for key in b.order + c.order where seen.insert(key).inserted {
            let baseEntry = b.byKey[key]
            let comparedEntry = c.byKey[key]
            switch (baseEntry, comparedEntry) {
            case let (nil, comp?):
                added.append(["name": comp.name, "values": comp.values])
            case let (base?, nil):
                removed.append(["name": base.name, "values": base.values])
            case let (base?, comp?) where base.values != comp.values:
                changed.append(["name": comp.name, "base": base.values, "compared": comp.values])
            default:
                break // identical
            }
        }

        var out: [String: Any] = [:]
        if !added.isEmpty { out["added"] = added }
        if !removed.isEmpty { out["removed"] = removed }
        if !changed.isEmpty { out["changed"] = changed }
        return out
    }

    // MARK: - Bodies

    /// Cap the fine-grained line diff so a huge body can't produce an O(n·m) blow-up
    /// or flood the agent's context; beyond it we report sizes only.
    private static let maxDiffLines = 400

    /// Diff two bodies. Empty result means byte-identical. For UTF-8 text bodies of
    /// manageable size we compute added/removed lines; otherwise we report byte
    /// counts and flag the payload as binary or too large to line-diff.
    static func bodyDiff(_ base: Data?, _ compared: Data?) -> [String: Any] {
        let baseData = base ?? Data()
        let comparedData = compared ?? Data()
        guard baseData != comparedData else { return [:] }

        var out: [String: Any] = [
            "baseBytes": baseData.count,
            "comparedBytes": comparedData.count,
        ]

        guard let baseText = String(data: baseData, encoding: .utf8),
              let comparedText = String(data: comparedData, encoding: .utf8) else {
            out["binary"] = true
            return out
        }

        let baseLines = baseText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let comparedLines = comparedText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard baseLines.count <= maxDiffLines, comparedLines.count <= maxDiffLines else {
            out["lineDiffSkipped"] = "body exceeds \(maxDiffLines) lines"
            out["baseLines"] = baseLines.count
            out["comparedLines"] = comparedLines.count
            return out
        }

        let (added, removed) = lineDiff(baseLines, comparedLines)
        if !added.isEmpty { out["addedLines"] = added }
        if !removed.isEmpty { out["removedLines"] = removed }
        return out
    }

    /// Longest-common-subsequence line diff: `removed` are lines in `a` not on the
    /// common subsequence, `added` are lines in `b` not on it.
    static func lineDiff(_ a: [String], _ b: [String]) -> (added: [String], removed: [String]) {
        let n = a.count, m = b.count
        // DP table of LCS lengths.
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var added: [String] = [], removed: [String] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                removed.append(a[i]); i += 1
            } else {
                added.append(b[j]); j += 1
            }
        }
        while i < n { removed.append(a[i]); i += 1 }
        while j < m { added.append(b[j]); j += 1 }
        return (added, removed)
    }
}
