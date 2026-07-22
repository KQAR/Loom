import Foundation

/// Serializes captured flows to HAR 1.2 (HTTP Archive) — the interchange format
/// Charles / Chrome DevTools / Proxyman read, so an agent can hand off a shareable
/// evidence bundle. Pure `[Flow] -> Data`; callers decide where to write it.
public enum HARExport {
    public static let creatorName = "Loom"

    /// Encode flows (any order) into pretty-printed HAR JSON, newest entries last.
    public static func encode(_ flows: [Flow], appVersion: String) -> Data {
        let entries = flows
            .sorted { $0.startedAt < $1.startedAt }
            .map { entry(for: $0) }
        let log: [String: Any] = [
            "log": [
                "version": "1.2",
                "creator": ["name": creatorName, "version": appVersion],
                "entries": entries,
            ],
        ]
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? JSONSerialization.data(withJSONObject: log, options: options)) ?? Data("{}".utf8)
    }

    private static func entry(for flow: Flow) -> [String: Any] {
        var out: [String: Any] = [
            "startedDateTime": iso8601String(flow.startedAt),
            "time": flow.durationMS ?? 0,
            "request": request(flow.request),
            "response": response(flow),
            "cache": [String: Any](),
            "timings": ["send": 0, "wait": flow.durationMS ?? 0, "receive": 0],
        ]
        // Custom fields carry Loom context; HAR permits `_`-prefixed extensions.
        if let app = flow.sourceApp { out["_sourceApp"] = app.name }
        if let rules = flow.appliedRules, !rules.isEmpty { out["_appliedRules"] = rules }
        if let error = flow.error { out["_error"] = error }
        return out
    }

    private static func request(_ request: CapturedRequest) -> [String: Any] {
        let bodyString = request.body.flatMap { String(data: $0, encoding: .utf8) }
        var out: [String: Any] = [
            "method": request.method,
            "url": request.url,
            "httpVersion": "HTTP/1.1",
            "headers": headers(request.headers),
            "queryString": queryString(request.url),
            "cookies": [Any](),
            "headersSize": -1,
            "bodySize": request.body?.count ?? 0,
        ]
        if let bodyString, !bodyString.isEmpty {
            out["postData"] = [
                "mimeType": contentType(request.headers) ?? "application/octet-stream",
                "text": bodyString,
            ]
        }
        return out
    }

    private static func response(_ flow: Flow) -> [String: Any] {
        guard let response = flow.response else {
            // No response captured (in-flight or errored) — a valid empty HAR response.
            return [
                "status": 0, "statusText": "", "httpVersion": "HTTP/1.1",
                "headers": [Any](), "cookies": [Any](),
                "content": ["size": 0, "mimeType": ""] as [String: Any],
                "redirectURL": "", "headersSize": -1, "bodySize": 0,
            ]
        }
        let bodyString = response.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var content: [String: Any] = [
            "size": response.body?.count ?? 0,
            "mimeType": contentType(response.headers) ?? "",
        ]
        if !bodyString.isEmpty { content["text"] = bodyString }
        return [
            "status": response.statusCode,
            "statusText": HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
            "httpVersion": "HTTP/1.1",
            "headers": headers(response.headers),
            "cookies": [Any](),
            "content": content,
            "redirectURL": location(response.headers) ?? "",
            "headersSize": -1,
            "bodySize": response.body?.count ?? 0,
        ]
    }

    private static func headers(_ pairs: [HeaderPair]) -> [[String: String]] {
        pairs.map { ["name": $0.name, "value": $0.value] }
    }

    private static func queryString(_ url: String) -> [[String: String]] {
        guard let items = URLComponents(string: url)?.queryItems else { return [] }
        return items.map { ["name": $0.name, "value": $0.value ?? ""] }
    }

    private static func contentType(_ headers: [HeaderPair]) -> String? {
        headers.value(named: "content-type")
    }

    private static func location(_ headers: [HeaderPair]) -> String? {
        headers.value(named: "location")
    }

    // A fresh formatter per call: ISO8601DateFormatter isn't Sendable, so it can't
    // be a shared static under strict concurrency. Cheap enough for an export.
    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
