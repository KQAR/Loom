import Foundation

/// An ordered HTTP header. Modeled as a list (not a dictionary) so we preserve
/// order and repeated header names exactly as they appeared on the wire. It is a
/// pure value (name + value) — no synthetic identity — so equality is value
/// equality (two identical headers compare equal), it encodes as just the wire
/// bytes, and replay/HAR round-trips don't mutate it. Views that need
/// `Identifiable` use positional identity (`ForEach(headers.indices, …)`).
public struct HeaderPair: Equatable, Codable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public extension [HeaderPair] {
    /// The first value whose header name matches case-insensitively (HTTP header
    /// names are case-insensitive), or nil. One definition of header-name equality
    /// for every layer that reads a header off a flow.
    func value(named name: String) -> String? {
        first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Whether any header matches `name` case-insensitively.
    func contains(named name: String) -> Bool {
        contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Drop every header whose name matches `name` case-insensitively — repeats
    /// included, since headers are an ordered list that can carry the same name
    /// twice. Uses `caseInsensitiveCompare` rather than `lowercased() ==` so a
    /// removal doesn't allocate a folded `String` per comparison.
    mutating func removeAll(named name: String) {
        removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Drop every header whose name matches any of `names` case-insensitively.
    /// Linear in `names` per header, which beats hashing a lowercased copy of every
    /// header name for the handful of names a rule or breakpoint edit removes.
    mutating func removeAll(namedAnyOf names: [String]) {
        guard !names.isEmpty else { return }
        removeAll { header in
            names.contains { $0.caseInsensitiveCompare(header.name) == .orderedSame }
        }
    }
}

public struct CapturedRequest: Equatable, Codable, Sendable {
    public var method: String
    public var url: String
    /// The HTTP version the **client** spoke to Loom (`HTTP/2`, `HTTP/1.1`,
    /// `HTTP/1.0`), or nil for a flow captured before this was recorded and for a
    /// request Loom synthesized rather than received.
    ///
    /// Deliberately a separate fact from `CapturedResponse.httpVersion`, which is
    /// Loom's *upstream* hop — and the two routinely disagree, because
    /// `NIOStreamingForwarder` re-originates every exchange as HTTP/1.1. A client
    /// that negotiated h2 and an origin that answered HTTP/1.1 is the ordinary
    /// case, and collapsing them into one field would make the h2 half of the
    /// picture unreportable: the response version alone reads "HTTP/1.1" for an
    /// h2 client, which is true of Loom's hop and a lie about the client's.
    public var httpVersion: String?
    public var headers: [HeaderPair]
    public var body: Data?
    /// Total body bytes that crossed the wire, recorded **only** when `body` holds
    /// a capped prefix of them — i.e. the capture cap kicked in. Nil means `body`
    /// is the whole payload. The peer always received every byte; only Loom's
    /// recorded copy stops, and a reader must be able to tell. Optional so flows
    /// persisted before this field existed still decode.
    public var fullBodyBytes: Int?

    /// Whether `body` is a prefix of what actually flowed rather than the whole of it.
    public var isBodyTruncated: Bool { fullBodyBytes != nil }

    /// Bytes this request's body had on the wire — the captured length, or the
    /// true length when the capture cap truncated it. Nil for a bodyless request.
    public var bodyBytes: Int? {
        if let fullBodyBytes { return fullBodyBytes }
        return body?.count
    }

    public init(
        method: String,
        url: String,
        httpVersion: String? = nil,
        headers: [HeaderPair],
        body: Data? = nil,
        fullBodyBytes: Int? = nil
    ) {
        self.method = method
        self.url = url
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
        self.fullBodyBytes = fullBodyBytes
    }
}

public struct CapturedResponse: Equatable, Codable, Sendable {
    public var statusCode: Int
    /// The HTTP version the upstream answered with (e.g. `HTTP/1.1`), or nil for a
    /// synthesized response (mock / block / mapLocal) that never hit the wire.
    public var httpVersion: String?
    public var headers: [HeaderPair]
    public var body: Data?
    /// Total body bytes that crossed the wire, recorded only when `body` holds a
    /// capped prefix of them (an SSE/long-poll/large download hitting the capture
    /// cap). Nil means `body` is complete. See `CapturedRequest.fullBodyBytes`.
    public var fullBodyBytes: Int?

    /// Whether `body` is a prefix of what actually flowed rather than the whole of it.
    public var isBodyTruncated: Bool { fullBodyBytes != nil }

    /// Bytes this response's body had after decoding — the captured length, or
    /// the true length when the capture cap truncated it. Not the wire size: the
    /// forwarder decompresses, and what crossed the wire is
    /// `FlowTransport.responseEncodedBodyBytes`.
    public var bodyBytes: Int? {
        if let fullBodyBytes { return fullBodyBytes }
        return body?.count
    }

    public init(
        statusCode: Int,
        httpVersion: String? = nil,
        headers: [HeaderPair],
        body: Data? = nil,
        fullBodyBytes: Int? = nil
    ) {
        self.statusCode = statusCode
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
        self.fullBodyBytes = fullBodyBytes
    }
}

/// The app that originated a captured request.
///
/// **Two ways this is known, and they are not interchangeable** — which is why
/// `attribution` is a stored field rather than something inferred from a nil
/// `pid`. A local process is resolved through libproc from the connection's
/// source port: exact, and it yields a bundle id and an icon. A LAN device's app
/// has no local pid to find, so the only evidence is what the app says about
/// itself in `User-Agent`: a name, no bundle id, and only as truthful as the
/// header.
///
/// Before this existed, `sourceApp` was nil for every phone request, so the
/// sidebar's Apps section listed Mac apps only and a device's traffic was one
/// undifferentiated bucket — the very case Loom is pointed at a phone to look at.
///
/// Icon is not stored here (a UI concern derived from `bundlePath`); the model
/// stays AppKit-free so engine modules can build it.
public struct SourceApp: Equatable, Codable, Sendable, Hashable {
    /// How this attribution was arrived at. A reader must be able to tell, because
    /// the two carry different weight: a pid is a fact about a socket, a
    /// `User-Agent` is a claim by the client and any app can send any string.
    public enum Attribution: String, Codable, Sendable, Hashable {
        /// libproc resolved the connection's source port to a running process.
        case process
        /// Parsed from the request's `User-Agent` — the only signal available for
        /// a device that is not this Mac.
        case userAgent
    }

    /// Display name — bundle display/name if it's an app, else the executable's
    /// basename; for a `userAgent` attribution, the product token the client sent.
    public var name: String
    public var bundleID: String?
    /// Path to the `.app` bundle when the origin is a bundled app; the UI resolves
    /// the icon from this. Nil for CLI tools / daemons, and always nil for a
    /// `userAgent` attribution — the binary is on another device.
    public var bundlePath: String?
    /// The local process id. **Nil for a `userAgent` attribution**, and optional
    /// rather than a sentinel: a phone's app has no pid on this machine, and `0`
    /// or `-1` there would be a number a reader could compare, filter and print.
    public var pid: Int32?
    public var attribution: Attribution

    public init(
        name: String,
        bundleID: String? = nil,
        bundlePath: String? = nil,
        pid: Int32? = nil,
        attribution: Attribution = .process
    ) {
        self.name = name
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.pid = pid
        self.attribution = attribution
    }

    /// An app known only by what it called itself in `User-Agent`.
    public static func fromUserAgent(name: String) -> SourceApp {
        SourceApp(name: name, attribution: .userAgent)
    }

    /// Hand-written so a flow persisted before `attribution` existed still
    /// decodes. Every one of those was resolved through libproc — that was the
    /// only path there was — so the absent key means `.process`, and the synthesized
    /// decoder's alternative is a store full of rows that fail to load at launch.
    /// `pid` needs no such care: it went from required to optional, and `decodeIfPresent`
    /// reads an old row's number and a new row's absence alike.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        bundlePath = try container.decodeIfPresent(String.self, forKey: .bundlePath)
        pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
        attribution = try container.decodeIfPresent(Attribution.self, forKey: .attribution) ?? .process
    }

    /// Stable grouping key: bundle id when available, else the display name.
    ///
    /// Deliberately **not** scoped by device, even though the sidebar now nests
    /// apps under the device they ran on. Two devices running the same app share a
    /// key on purpose — that is what makes "the same app, on the phone and on this
    /// Mac" a comparable thing rather than two unrelated buckets — and the sidebar
    /// scopes by pairing the key with the device it drew it under.
    public var groupingKey: String { bundleID ?? name }
}

/// Why a flow failed. A distinct type (not a bare `String`) so failure is
/// modeled explicitly and can grow structured fields later without churning
/// every call site.
public struct FlowError: Equatable, Codable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// One traffic rule that acted on a flow — the audit trail for "what did the
/// rules do to my traffic". Carries the rule's `id` (so the UI/MCP can link back
/// to the live rule) alongside the display `name`.
public struct AppliedRule: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Where a flow is in its lifecycle. Modeled as a sum type so the illegal
/// combinations the old triple of optionals allowed — a `completedAt` with no
/// response, a response *and* an error on a still-"pending" flow — are simply
/// unrepresentable. `.streaming` covers the window where the response head is
/// known but the body is still arriving (SSE / long-poll / a growing WebSocket).
public enum FlowOutcome: Equatable, Codable, Sendable {
    /// Request sent; no response head yet.
    case pending
    /// Response head known, body still arriving. Not terminal (no `completedAt`).
    case streaming(CapturedResponse)
    /// Finished normally at `at`.
    case completed(CapturedResponse, at: Date)
    /// Failed at `at`; `partialResponse` holds whatever arrived before the error
    /// (a mid-stream failure), or nil if it failed before the head.
    case failed(FlowError, at: Date, partialResponse: CapturedResponse?)
}

/// A single captured (or replayed) request/response exchange.
public struct Flow: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var request: CapturedRequest
    public var startedAt: Date
    /// Lifecycle + response/error, modeled so illegal states can't occur.
    public var outcome: FlowOutcome
    /// When the response *head* arrived — the first byte back from upstream.
    /// Splits the exchange into server think-time (`ttfbMS`) and transfer time
    /// (`receiveMS`), which a single `durationMS` cannot: "this call is slow" has
    /// completely different causes depending on which half it lands in. Nil while
    /// pending, for a flow that failed before any head, and for flows captured
    /// before this was recorded.
    public var firstByteAt: Date?
    /// Non-nil when this flow was produced by replaying another flow.
    public var replayedFrom: UUID?
    /// The local app/process that made the request, when it could be resolved.
    public var sourceApp: SourceApp?
    /// The device the request came from (this Mac or a LAN device), identified by
    /// the connection's remote IP and typed from its User-Agent.
    public var sourceDevice: SourceDevice?
    /// Traffic rules that acted on this exchange (mocked, rewrote, re-mapped,
    /// blocked or delayed it), in the order they applied. Nil when the exchange
    /// passed through untouched.
    public var appliedRules: [AppliedRule]?
    /// Non-nil once this flow is a WebSocket connection (its HTTP upgrade
    /// succeeded); frames captured in either direction append here over time.
    public var webSocketMessages: [WebSocketMessage]?
    /// Frames the capture cap dropped from `webSocketMessages` (they were still
    /// relayed to the peer). Nil when nothing was dropped — so a reader can tell a
    /// complete frame log from a partial one.
    public var webSocketDroppedMessages: Int?
    /// Set when frame capture for this WebSocket gave up mid-connection — the byte
    /// stream stopped framing as WebSocket, so parsing it further is guesswork.
    /// The connection itself is unaffected (the relay is byte-transparent); what
    /// this says is that `webSocketMessages` stopped growing before the socket did,
    /// which is otherwise indistinguishable from a socket that went quiet.
    public var webSocketCaptureError: String?
    /// Set when this flow was loaded from a file (a HAR import) rather than observed
    /// on the wire, naming where it came from. Imported traffic sits in the same
    /// store as captured traffic — that's the point, it can be inspected, diffed and
    /// replayed the same way — so it has to be labelled, or a reader would take
    /// someone else's capture for something that just happened on this machine.
    public var importedFrom: String?
    /// Set when the in-memory ring dropped this flow's bodies to stay inside its byte
    /// budget **with nowhere to hydrate them back from** — an embedder running the
    /// engine without persistence (`ProxyEngine(persistFlows: false)`).
    ///
    /// Only ever `true`; absent is the normal case. It exists because the two ways a
    /// body goes missing need different next moves and are otherwise identical on the
    /// wire-format: a body capped *at capture* is a `fullBodyBytes` prefix and the fix
    /// is a bigger capture cap, while this one was captured whole and then discarded,
    /// and the fix is turning persistence on. Loom itself always persists, so this is
    /// the embedding path's flag; each side's `fullBodyBytes` carries the size either
    /// way, so `isBodyTruncated` and every reader of it stay correct without knowing
    /// which happened.
    public var bodiesEvicted: Bool?
    /// How the exchange travelled — upstream address, connection reuse, both
    /// legs' TLS, the encoded response size. Nil for an exchange that never
    /// reached the network (a mocked or blocked response, a request still pending
    /// its head) and for flows captured before this was recorded.
    public var transport: FlowTransport?

    public init(
        id: UUID = UUID(),
        request: CapturedRequest,
        startedAt: Date,
        outcome: FlowOutcome = .pending,
        firstByteAt: Date? = nil,
        replayedFrom: UUID? = nil,
        sourceApp: SourceApp? = nil,
        sourceDevice: SourceDevice? = nil,
        appliedRules: [AppliedRule]? = nil,
        webSocketMessages: [WebSocketMessage]? = nil,
        webSocketDroppedMessages: Int? = nil,
        webSocketCaptureError: String? = nil,
        importedFrom: String? = nil,
        bodiesEvicted: Bool? = nil,
        transport: FlowTransport? = nil
    ) {
        self.id = id
        self.request = request
        self.startedAt = startedAt
        self.outcome = outcome
        self.firstByteAt = firstByteAt
        self.replayedFrom = replayedFrom
        self.sourceApp = sourceApp
        self.sourceDevice = sourceDevice
        self.appliedRules = appliedRules
        self.webSocketMessages = webSocketMessages
        self.webSocketDroppedMessages = webSocketDroppedMessages
        self.webSocketCaptureError = webSocketCaptureError
        self.importedFrom = importedFrom
        self.bodiesEvicted = bodiesEvicted
        self.transport = transport
    }

    // MARK: Read accessors derived from `outcome` (keep call sites terse)

    /// The response, real or partial — nil only while still `.pending`.
    public var response: CapturedResponse? {
        switch outcome {
        case .pending: return nil
        case let .streaming(r): return r
        case let .completed(r, _): return r
        case let .failed(_, _, partial): return partial
        }
    }

    /// When the exchange reached a terminal state; nil while pending/streaming.
    public var completedAt: Date? {
        switch outcome {
        case .pending, .streaming: return nil
        case let .completed(_, at): return at
        case let .failed(_, at, _): return at
        }
    }

    public var flowError: FlowError? {
        if case let .failed(error, _, _) = outcome { return error }
        return nil
    }

    /// Failure message, for the many call sites that just want the text.
    public var error: String? { flowError?.message }

    /// True once the exchange upgraded to WebSocket.
    public var isWebSocket: Bool { webSocketMessages != nil }

    public var statusCode: Int? { response?.statusCode }

    /// Host of the request URL. Read on every render of a host-filtered list, on
    /// every `FlowQuery` candidate and on every persistence write, so it goes
    /// through `URLHost` (a direct authority scan, falling back to `URLComponents`
    /// for unusual shapes) rather than building a `URLComponents` each time.
    public var host: String? {
        URLHost.host(ofURLString: request.url)
    }

    /// Rounded, not truncated: a 49.9 ms exchange is 50 ms, not 49 ms. The difference
    /// is invisible one flow at a time and systematic in aggregate — truncation biases
    /// every percentile in `FlowStats` downward by up to a millisecond.
    public var durationMS: Int? {
        guard let completedAt else { return nil }
        return Int((completedAt.timeIntervalSince(startedAt) * 1000).rounded())
    }

    /// Time to first byte: request sent → response head back. This is the part the
    /// server is responsible for; `receiveMS` is the part the payload size and the
    /// link are responsible for.
    public var ttfbMS: Int? {
        guard let firstByteAt else { return nil }
        return Int((max(0, firstByteAt.timeIntervalSince(startedAt)) * 1000).rounded())
    }

    /// Response head → last byte: how long the body took to transfer.
    public var receiveMS: Int? {
        guard let firstByteAt, let completedAt else { return nil }
        return Int((max(0, completedAt.timeIntervalSince(firstByteAt)) * 1000).rounded())
    }
}
