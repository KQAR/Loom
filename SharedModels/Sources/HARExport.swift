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
        if let body = request.body, !body.isEmpty {
            let rendered = renderBody(body)
            var postData: [String: Any] = [
                "mimeType": contentType(request.headers) ?? "application/octet-stream",
                "text": rendered.text,
            ]
            // postData has no spec `encoding` field, so flag base64 as an extension.
            if rendered.base64 { postData["_encoding"] = "base64" }
            out["postData"] = postData
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
        var content: [String: Any] = [
            "size": response.body?.count ?? 0,
            "mimeType": contentType(response.headers) ?? "",
        ]
        if let body = response.body, !body.isEmpty {
            let rendered = renderBody(body)
            content["text"] = rendered.text
            // Standard HAR content field — DevTools decodes this automatically.
            if rendered.base64 { content["encoding"] = "base64" }
        }
        return [
            "status": response.statusCode,
            "statusText": reasonPhrase(response.statusCode),
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

    /// Render a body for HAR: UTF-8 text when decodable, else base64 (so binary
    /// payloads — images, protobuf, non-UTF-8 — aren't silently dropped, which was
    /// a data-loss bug on every non-text response).
    private static func renderBody(_ data: Data) -> (text: String, base64: Bool) {
        if let text = String(data: data, encoding: .utf8) { return (text, false) }
        return (data.base64EncodedString(), true)
    }

    /// A fixed reason phrase so exports are deterministic; the OS
    /// `localizedString(forStatusCode:)` varies by locale.
    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return ""
        }
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
