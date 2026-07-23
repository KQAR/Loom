import Foundation

/// Serializes captured flows to HAR 1.2 (HTTP Archive) — the interchange format
/// Charles / Chrome DevTools / Proxyman read, so an agent can hand off a shareable
/// evidence bundle. Pure `[Flow] -> Data`; callers decide where to write it.
///
/// The document is modeled as typed `Encodable` structs (rather than untyped
/// `[String: Any]`) so the shape is checked at compile time and nil fields drop
/// out via synthesized `encodeIfPresent`. Loom's own context rides on the HAR
/// `_`-prefixed extension keys.
public enum HARExport {
    public static let creatorName = "Loom"

    /// Encode flows (any order) into pretty-printed HAR JSON, newest entries last.
    public static func encode(_ flows: [Flow], appVersion: String) -> Data {
        let entries = flows
            .sorted { $0.startedAt < $1.startedAt }
            .map(Entry.init(flow:))
        let document = Document(log: Log(
            version: "1.2",
            creator: Creator(name: creatorName, version: appVersion),
            entries: entries
        ))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(document)) ?? Data("{}".utf8)
    }

    // MARK: - HAR document model

    private struct Document: Encodable { let log: Log }

    private struct Log: Encodable {
        let version: String
        let creator: Creator
        let entries: [Entry]
    }

    private struct Creator: Encodable {
        let name: String
        let version: String
    }

    private struct Entry: Encodable {
        let startedDateTime: String
        let time: Int
        let request: Request
        let response: Response
        let cache: Cache
        let timings: Timings
        let sourceApp: String?
        let appliedRules: [String]?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case startedDateTime, time, request, response, cache, timings
            // HAR permits `_`-prefixed vendor extensions.
            case sourceApp = "_sourceApp"
            case appliedRules = "_appliedRules"
            case error = "_error"
        }

        init(flow: Flow) {
            startedDateTime = HARExport.iso8601String(flow.startedAt)
            time = flow.durationMS ?? 0
            request = Request(flow.request)
            response = Response(flow)
            cache = Cache()
            timings = Timings(send: 0, wait: flow.durationMS ?? 0, receive: 0)
            sourceApp = flow.sourceApp?.name
            let rules = flow.appliedRules?.map(\.name)
            appliedRules = (rules?.isEmpty ?? true) ? nil : rules
            error = flow.error
        }
    }

    private struct Cache: Encodable {} // HAR requires the key; we don't model cache.

    private struct Timings: Encodable {
        let send: Int
        let wait: Int
        let receive: Int
    }

    private struct NameValue: Encodable {
        let name: String
        let value: String
    }

    private struct Request: Encodable {
        let method: String
        let url: String
        let httpVersion: String
        let headers: [NameValue]
        let queryString: [NameValue]
        let cookies: [NameValue]
        let headersSize: Int
        let bodySize: Int
        let postData: PostData?

        init(_ request: CapturedRequest) {
            method = request.method
            url = request.url
            httpVersion = "HTTP/1.1"
            headers = HARExport.nameValues(request.headers)
            queryString = HARExport.queryString(request.url)
            cookies = []
            headersSize = -1
            bodySize = request.body?.count ?? 0
            if let body = request.body, !body.isEmpty {
                let rendered = HARExport.renderBody(body)
                postData = PostData(
                    mimeType: HARExport.contentType(request.headers) ?? "application/octet-stream",
                    text: rendered.text,
                    encoding: rendered.base64 ? "base64" : nil
                )
            } else {
                postData = nil
            }
        }
    }

    private struct PostData: Encodable {
        let mimeType: String
        let text: String
        let encoding: String?
        // postData has no spec `encoding` field, so flag base64 as an extension.
        enum CodingKeys: String, CodingKey {
            case mimeType, text
            case encoding = "_encoding"
        }
    }

    private struct Response: Encodable {
        let status: Int
        let statusText: String
        let httpVersion: String
        let headers: [NameValue]
        let cookies: [NameValue]
        let content: Content
        let redirectURL: String
        let headersSize: Int
        let bodySize: Int

        init(_ flow: Flow) {
            guard let response = flow.response else {
                // No response captured (in-flight or errored) — a valid empty HAR response.
                status = 0
                statusText = ""
                httpVersion = "HTTP/1.1"
                headers = []
                cookies = []
                content = Content(size: 0, mimeType: "", text: nil, encoding: nil)
                redirectURL = ""
                headersSize = -1
                bodySize = 0
                return
            }
            status = response.statusCode
            statusText = HARExport.reasonPhrase(response.statusCode)
            httpVersion = response.httpVersion ?? "HTTP/1.1"
            headers = HARExport.nameValues(response.headers)
            cookies = []
            var text: String?
            var encoding: String?
            if let body = response.body, !body.isEmpty {
                let rendered = HARExport.renderBody(body)
                text = rendered.text
                // Standard HAR content field — DevTools decodes this automatically.
                encoding = rendered.base64 ? "base64" : nil
            }
            content = Content(
                size: response.body?.count ?? 0,
                mimeType: HARExport.contentType(response.headers) ?? "",
                text: text,
                encoding: encoding
            )
            redirectURL = HARExport.location(response.headers) ?? ""
            headersSize = -1
            bodySize = response.body?.count ?? 0
        }
    }

    private struct Content: Encodable {
        let size: Int
        let mimeType: String
        let text: String?
        let encoding: String?
    }

    // MARK: - Helpers

    private static func nameValues(_ pairs: [HeaderPair]) -> [NameValue] {
        pairs.map { NameValue(name: $0.name, value: $0.value) }
    }

    private static func queryString(_ url: String) -> [NameValue] {
        guard let items = URLComponents(string: url)?.queryItems else { return [] }
        return items.map { NameValue(name: $0.name, value: $0.value ?? "") }
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
