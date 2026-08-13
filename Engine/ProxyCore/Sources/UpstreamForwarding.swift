import Foundation
import LoomSharedModels

/// The upstream leg of a proxied exchange, factored out so the plain-HTTP path,
/// the TLS-interception path, and replay all re-send through one place — and so
/// tests can inject a deterministic stub instead of hitting the network.
struct ForwardResult: Sendable {
    var statusCode: Int
    /// Upstream's HTTP version (nil for a synthesized mock/block/local response).
    var httpVersion: String?
    var headers: [HeaderPair]
    var body: Data
    /// The origin's trailer field section, or nil when it sent none. This is where
    /// gRPC returns its result (`grpc-status`), so a forwarder that drops it turns
    /// every failed call into one that looks like it succeeded and then stopped.
    var trailers: [HeaderPair]?
    /// How the exchange travelled, when it travelled at all. Nil for a response
    /// that never touched a socket — which is a fact worth keeping distinct from
    /// a zeroed-out transport, because "mocked" and "connected but unmeasured"
    /// are different answers.
    var transport: FlowTransport?

    init(
        statusCode: Int,
        httpVersion: String? = nil,
        headers: [HeaderPair],
        body: Data,
        trailers: [HeaderPair]? = nil,
        transport: FlowTransport? = nil
    ) {
        self.statusCode = statusCode
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
        self.trailers = trailers
        self.transport = transport
    }
}

/// The lifecycle of one proxied exchange, so the proxy can relay a response to the
/// client chunk-by-chunk (SSE / long-poll / large downloads) instead of buffering the
/// whole body first. Ordering: `metadata?` → `head` → `body`* → `end` (a terminal
/// `end`, or the stream finishes throwing on failure).
enum UpstreamResponseEvent: Sendable {
    /// Exchange-level metadata known *before* the response — currently the traffic
    /// rules that acted on the request. Emitted once, first, by `RuleApplyingForwarder`,
    /// and omitted entirely when no rule matched (so a no-rule passthrough yields no
    /// extra event). Because it precedes the network call, it is the reason a failed
    /// exchange can still record its rule hits: it arrives before any `head` or error.
    case metadata(appliedRules: [AppliedRule])
    /// How this exchange travelled. Emitted by the NIO client at most twice and
    /// **merged**, never replaced (`FlowTransport.merging`): once with the head,
    /// carrying everything the connection already knows (peer address, reuse, both
    /// TLS legs, the origin's `Content-Encoding`), and once before `end` carrying
    /// the encoded body size, which is only a number once the body has finished.
    ///
    /// Optional in practice: a forwarder that synthesizes a response emits none,
    /// and a consumer that doesn't care ignores the case. It is deliberately not
    /// folded into `.head` — the second instalment has no head to ride on, and a
    /// head that had to wait for the body would stop the relay streaming.
    case transport(FlowTransport)
    case head(statusCode: Int, httpVersion: String?, headers: [HeaderPair])
    case body(Data)
    /// The response finished, carrying the origin's trailer section when it sent
    /// one. Nil and `[]` are different answers (no trailer section vs an empty
    /// one), which is why this is not a plain array.
    case end(trailers: [HeaderPair]?)
}

/// What the **client** spoke to Loom, as far as the upstream leg needs to care.
///
/// It exists because Loom re-originates every exchange, and re-originating an h2
/// request as HTTP/1.1 is not a neutral translation: gRPC origins are h2-only, h2
/// `cookie` crumbs have to be coalesced into a single line an origin's h1 front-end
/// may then refuse, and response trailers only survive an h1 hop because that hop is
/// chunked. So the client's protocol is carried down and the upstream leg matches it.
///
/// Deliberately **not** "negotiate h2 with every origin that offers it". An h1 client
/// gets an h1 upstream: a proxy that upgraded on its own would make Loom's presence
/// change which protocol the origin sees for traffic nobody asked it to change, and
/// every h2-specific origin behaviour would then be Loom's to explain.
enum ClientWireProtocol: Sendable {
    case http1
    /// HTTP/2 negotiated over TLS (ALPN `h2`).
    case http2
    /// HTTP/2 in cleartext, with prior knowledge (h2c).
    ///
    /// Kept apart from `http2` because the upstream decision differs, and getting
    /// that wrong hangs the exchange. Over TLS, ALPN *asks* the origin and takes
    /// `http/1.1` for an answer. In cleartext there is nothing to ask: sending the
    /// connection preface is a commitment. The only evidence that an origin speaks
    /// h2c is that the client just spoke it — so an h2c preface goes out **only** for
    /// a client that itself arrived over h2c. An h2-over-TLS request that a
    /// `mapRemote` rule retargets at an `http://` dev server gets a plain HTTP/1.1
    /// leg, which is what that server can read.
    case http2Cleartext

    /// From what Loom recorded about the client's leg. A TLS version is what
    /// separates the two h2 cases: an h2c connection has none, by definition.
    ///
    /// Anything not recognisably h2 is h1, which is the safe direction — the worst
    /// case is exactly the behaviour Loom had before this existed.
    init(httpVersion: String?, clientTLSVersion: String?) {
        guard httpVersion?.hasPrefix("HTTP/2") == true else {
            self = .http1
            return
        }
        self = clientTLSVersion == nil ? .http2Cleartext : .http2
    }

    var isHTTP2: Bool { self != .http1 }
}

protocol UpstreamForwarding: Sendable {
    /// Buffered send — the whole request body is already in hand (replay, or a body
    /// a rule/breakpoint had to materialize). Also the buffered fallback the
    /// decorators use when they must see the full body.
    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult
    /// Streaming send: the request body is a back-pressured `RequestBody` and the
    /// response is relayed chunk-by-chunk. The default adapter below drains the body
    /// and calls buffered `forward`, so test stubs only need `forward`; the NIO
    /// client and the decorators override this with real streaming.
    func forwardStream(method: String, url: URL, headers: [HeaderPair], body: RequestBody) -> AsyncThrowingStream<UpstreamResponseEvent, Error>
    /// Same, plus **who** is asking — the originating app/device, so a rule or
    /// breakpoint can be scoped to one client. Only the matching decorators care; the
    /// default below drops it, which is why the NIO client and test stubs need not
    /// implement it.
    ///
    /// Production always sends through this variant (`CapturedExchange` and replay), so
    /// an origin-scoped rule sees an origin whenever one is knowable.
    func forwardStream(
        method: String, url: URL, headers: [HeaderPair], body: RequestBody, origin: RequestOrigin?
    ) -> AsyncThrowingStream<UpstreamResponseEvent, Error>

    /// Same again, plus what the client spoke. Every production caller uses this one;
    /// the default below drops the protocol, so a test stub still only needs
    /// `forward`. A decorator must override it to pass the value down — the compiler
    /// cannot catch that, which is why `EngineInvariantTests` checks the h2 leg
    /// survives the rules chain.
    func forwardStream(
        method: String, url: URL, headers: [HeaderPair], body: RequestBody,
        origin: RequestOrigin?, clientProtocol: ClientWireProtocol
    ) -> AsyncThrowingStream<UpstreamResponseEvent, Error>

    /// Whether anything in this forwarding chain currently matches on the
    /// originating *app* — i.e. whether forwarding must wait for the libproc
    /// resolver before the first byte goes upstream. Device scoping doesn't
    /// count: the device is known from the connection, no resolver needed.
    /// Consulted per exchange by `CapturedExchange`; when false, resolution
    /// runs concurrently with the forward and only backfills the flow.
    var requiresSourceAppResolution: Bool { get }
}

extension UpstreamForwarding {
    /// A forwarder that matches on nothing never needs to wait for attribution.
    var requiresSourceAppResolution: Bool { false }

    /// A forwarder that matches on nothing has no use for the origin.
    func forwardStream(
        method: String, url: URL, headers: [HeaderPair], body: RequestBody, origin: RequestOrigin?
    ) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
        forwardStream(method: method, url: url, headers: headers, body: body)
    }

    /// A forwarder with one upstream shape has no use for the client's protocol.
    func forwardStream(
        method: String, url: URL, headers: [HeaderPair], body: RequestBody,
        origin: RequestOrigin?, clientProtocol: ClientWireProtocol
    ) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
        forwardStream(method: method, url: url, headers: headers, body: body, origin: origin)
    }

    func forwardStream(method: String, url: URL, headers: [HeaderPair], body: RequestBody) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let collected = try await body.collect()
                    let result = try await forward(method: method, url: url, headers: headers, body: collected.body)
                    if let transport = result.transport { continuation.yield(.transport(transport)) }
                    continuation.yield(.head(statusCode: result.statusCode, httpVersion: result.httpVersion, headers: result.headers))
                    if !result.body.isEmpty { continuation.yield(.body(result.body)) }
                    continuation.yield(.end(trailers: result.trailers))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension AsyncThrowingStream where Element == UpstreamResponseEvent, Failure == Error {
    /// Fold a response event stream into a buffered `ForwardResult` — the single place
    /// that reassembles `.head` / `.body` / `.end`. Applied rules ride the `.metadata`
    /// event and are consumed there (`StreamRelay` / replay), so they are not carried on
    /// the buffered result. Shared by every buffered `forward`; replay folds inline
    /// instead because it needs the rules even when the stream fails mid-flight.
    func collect() async throws -> ForwardResult {
        var statusCode = 200
        var httpVersion: String?
        var headers: [HeaderPair] = []
        var body = Data()
        var trailers: [HeaderPair]?
        var transport: FlowTransport?
        for try await event in self {
            switch event {
            case .metadata: break
            case let .transport(info): transport = (transport ?? FlowTransport()).merging(info)
            case let .head(code, version, hdrs): statusCode = code; httpVersion = version; headers = hdrs
            case let .body(chunk): body.append(chunk)
            case let .end(sectionTrailers): trailers = sectionTrailers
            }
        }
        return ForwardResult(
            statusCode: statusCode, httpVersion: httpVersion, headers: headers, body: body,
            trailers: trailers, transport: transport
        )
    }
}
