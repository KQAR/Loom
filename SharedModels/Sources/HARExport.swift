import Foundation
import Synchronization

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
        let serverIPAddress: String?
        /// How the exchange travelled. `FlowTransport` is `Encodable` with exactly
        /// the shape wanted here, so it ships whole rather than being flattened
        /// into six `_`-prefixed keys that would then have to be kept in step.
        let transport: FlowTransport?

        enum CodingKeys: String, CodingKey {
            case startedDateTime, time, request, response, cache, timings
            // Standard HAR 1.2 optional fields, not extensions.
            case serverIPAddress
            // HAR permits `_`-prefixed vendor extensions.
            case sourceApp = "_sourceApp"
            case appliedRules = "_appliedRules"
            case error = "_error"
            case transport = "_transport"
        }

        init(flow: Flow) {
            startedDateTime = HARExport.iso8601String(flow.startedAt)
            time = flow.durationMS ?? 0
            request = Request(flow.request)
            response = Response(flow)
            cache = Cache()
            timings = Timings(flow: flow)

            sourceApp = flow.sourceApp?.name
            let rules = flow.appliedRules?.map(\.name)
            appliedRules = (rules?.isEmpty ?? true) ? nil : rules
            error = flow.error
            // HAR 1.2 has a standard slot for the origin's address and none for
            // anything else here, so the address goes in it — stripped of the port,
            // which the field is defined as not carrying — and the rest travels as
            // one vendor extension rather than six.
            serverIPAddress = flow.transport?.remoteAddress.map(HARExport.ipOnly)
            transport = flow.transport
        }
    }

    private struct Cache: Encodable {} // HAR requires the key; we don't model cache.

    /// HAR `timings`. `wait` is server think-time (request sent → response head)
    /// and `receive` is body transfer; previously the whole duration was reported
    /// as `wait` with `receive: 0`, which told a reader "the server is slow" even
    /// for a fast endpoint streaming a large payload. `-1` is HAR's "not measured",
    /// used for the phases Loom doesn't time (`blocked`/`dns`/`connect`/`ssl`) and
    /// for `wait`/`receive` on a flow captured before TTFB was recorded — better an
    /// explicit "unknown" than a plausible wrong number.
    private struct Timings: Encodable {
        let blocked: Int
        let dns: Int
        let connect: Int
        let send: Int
        let wait: Int
        let receive: Int
        let ssl: Int

        init(flow: Flow) {
            blocked = -1
            dns = -1
            connect = -1
            ssl = -1
            // Loom writes the request in one go and doesn't time it separately.
            send = 0
            if let ttfb = flow.ttfbMS {
                wait = ttfb
                receive = flow.receiveMS ?? -1
            } else {
                wait = -1
                receive = -1
            }
        }
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
        /// Vendor extension: `postData.text` is only a prefix of `bodySize` bytes
        /// because Loom's capture cap tripped. HAR has no standard marker for a
        /// partial body, and silently shipping the prefix under the real size would
        /// misrepresent the capture.
        let bodyTruncated: Bool?

        enum CodingKeys: String, CodingKey {
            case method, url, httpVersion, headers, queryString, cookies, headersSize, bodySize, postData
            case bodyTruncated = "_bodyTruncated"
        }

        init(_ request: CapturedRequest) {
            method = request.method
            url = request.url
            // What the client spoke, when Loom recorded it. The fallback is for a
            // flow captured before that was recorded, and for an imported HAR that
            // omitted it — HAR requires the key, so there is no way to say nothing.
            httpVersion = request.httpVersion ?? "HTTP/1.1"
            headers = HARExport.nameValues(request.headers)
            queryString = HARExport.queryString(request.url)
            cookies = []
            headersSize = -1
            // The size that crossed the wire, not the size we kept.
            bodySize = request.fullBodyBytes ?? request.body?.count ?? 0
            bodyTruncated = request.isBodyTruncated ? true : nil
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
        /// Vendor extension — see `Request.bodyTruncated`.
        let bodyTruncated: Bool?

        enum CodingKeys: String, CodingKey {
            case status, statusText, httpVersion, headers, cookies, content, redirectURL, headersSize, bodySize
            case bodyTruncated = "_bodyTruncated"
        }

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
                bodyTruncated = nil
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
                // Wire size, not captured size — see `bodyTruncated`.
                size: response.fullBodyBytes ?? response.body?.count ?? 0,
                mimeType: HARExport.contentType(response.headers) ?? "",
                text: text,
                encoding: encoding
            )
            redirectURL = HARExport.location(response.headers) ?? ""
            headersSize = -1
            bodySize = response.fullBodyBytes ?? response.body?.count ?? 0
            bodyTruncated = response.isBodyTruncated ? true : nil
        }
    }

    private struct Content: Encodable {
        let size: Int
        let mimeType: String
        let text: String?
        let encoding: String?
    }

    // MARK: - Helpers

    /// HAR's `serverIPAddress` is the address alone. `FlowTransport.remoteAddress`
    /// carries the port too (`93.184.216.34:443`, `[::1]:8080`), which is the more
    /// useful reading everywhere else — so it is trimmed here rather than stored
    /// twice.
    private static func ipOnly(_ address: String) -> String {
        if address.hasPrefix("["), let close = address.firstIndex(of: "]") {
            return String(address[address.index(after: address.startIndex) ..< close])
        }
        guard let colon = address.lastIndex(of: ":") else { return address }
        return String(address[address.startIndex ..< colon])
    }

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

    /// One shared formatter, guarded by a lock — same shape as `RegexCache`.
    /// `ISO8601DateFormatter` init is expensive (locale/calendar/timezone setup) and
    /// an export runs this once per flow, so a fresh formatter per call cost a
    /// 10k-flow export thousands of allocations. `formatOptions` is set once and
    /// never varies per call, so the instance is safely reusable; the lock is what
    /// makes the shared state sound (unlike the MCP renderer's copy, `HARExport` is
    /// not confined to a single actor or queue).
    /// The formatter lives *inside* the `Mutex`, which is what retires the
    /// `nonisolated(unsafe)` this used to need: `ISO8601DateFormatter` is not
    /// `Sendable`, and a `Mutex` is `Sendable` whatever it holds precisely because the
    /// only way to touch the value is under the lock.
    private static let iso8601 = Mutex<ISO8601DateFormatter>({
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }())

    private static func iso8601String(_ date: Date) -> String {
        iso8601.withLock { $0.string(from: date) }
    }
}
