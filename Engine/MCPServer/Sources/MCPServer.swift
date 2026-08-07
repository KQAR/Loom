import Foundation
import os
import NIOCore
import NIOPosix
import NIOHTTP1
import LoomSharedModels

/// A tool ran but failed for a domain reason (flow/rule not found, replay or file
/// write failed). Per the MCP spec this is returned as a tool result with
/// `isError: true` — in-band so the model sees it — NOT as a JSON-RPC protocol
/// error (which several clients swallow or treat as a turn-ending fault). JSON-RPC
/// errors (`MCPError`) are reserved for "couldn't dispatch": unknown tool,
/// unparseable/invalid params.
public struct MCPToolFailure: Error {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public enum MCPError: Error {
    case parseError(String)
    case invalidRequest(String)
    case methodNotFound(String)
    case invalidParams(String)
    case internalError(String)
    /// An advertised tool that doesn't exist. `-32602` rather than `-32601`: the
    /// *method* (`tools/call`) was found, it's the `name` parameter that is wrong,
    /// and the spec's tool error handling assigns exactly this code to "unknown tool".
    case unknownTool(String)
    /// The mirrored HTTP headers disagree with the body, or a required one is missing.
    /// Modern era only — nothing mirrors headers before `2026-07-28`.
    case headerMismatch(String)
    /// The client asked for a revision Loom doesn't serve. The `supported` list in
    /// `data` is the client's retry instruction, so this error is the *only* way a
    /// modern client can renegotiate downwards; omitting it strands them.
    case unsupportedProtocolVersion(requested: String)

    var code: Int {
        switch self {
        case .parseError: return -32_700
        case .invalidRequest: return -32_600
        case .methodNotFound: return -32_601
        case .invalidParams, .unknownTool: return -32_602
        case .internalError: return -32_603
        case .headerMismatch: return -32_020
        case .unsupportedProtocolVersion: return -32_022
        }
    }

    var message: String {
        switch self {
        case let .parseError(m), let .invalidRequest(m), let .methodNotFound(m),
             let .invalidParams(m), let .internalError(m), let .headerMismatch(m):
            return m
        case let .unknownTool(name):
            return "unknown tool: \(name)"
        case .unsupportedProtocolVersion:
            return "Unsupported protocol version"
        }
    }

    /// The JSON-RPC `error.data` member, where a machine-actionable payload goes.
    var data: Any? {
        switch self {
        case let .unsupportedProtocolVersion(requested):
            return ["supported": MCPProtocol.supported, "requested": requested]
        default:
            return nil
        }
    }

    /// The HTTP status this error is returned with in the **modern** era, where the
    /// status carries protocol meaning: `404` distinguishes an unknown method from a
    /// legacy server that doesn't host the endpoint at all, and `400` is what the
    /// spec mandates for every validation failure. Legacy replies ignore this and
    /// stay on `200`.
    var modernStatusCode: Int {
        switch self {
        case .methodNotFound: return 404
        case .internalError: return 500
        case .parseError, .invalidRequest, .invalidParams, .unknownTool,
             .headerMismatch, .unsupportedProtocolVersion:
            return 400
        }
    }
}

/// A local HTTP JSON-RPC endpoint (`POST /mcp`) implementing the slice of MCP that a
/// tools-only server needs, in **both** protocol eras: `server/discover`,
/// `tools/list`, `tools/call`, `ping`, and — for clients still on `2025-06-18` —
/// `initialize`. See `MCPProtocol` for how an incoming request's era is decided.
///
/// `@unchecked Sendable` so the app (Swift 6) can hand the boot-time instance to
/// its `start()` task without a data-race diagnostic (Xcode 26.5 promotes that to
/// an error). Safe in practice: `engine`/`appVersion`/`token` are immutable, the
/// `EventLoopGroup` is thread-safe, and `channel` is written once at boot. Matches
/// the `@unchecked Sendable` treatment of `MCPDispatcher`/`MCPHTTPHandler`.
public final class MCPServer: @unchecked Sendable {
    /// The newest revision this server speaks. Reported by `get_version` and used as
    /// the `initialize` answer when a legacy client asks for something unknown; the
    /// full dual-era set lives in `MCPProtocol.supported`.
    public static let protocolVersion = MCPProtocol.latest
    /// Fixed loopback port for the HTTP MCP endpoint, so a static client config
    /// (the Claude Code plugin's `.mcp.json`, `http://127.0.0.1:9092/mcp`) can
    /// reach it without discovering a random port. The `loom-mcp` stdio bridge
    /// still reads the handshake, so it keeps working if this ever falls back.
    public static let defaultPort = 9092

    private let engine: ProxyControlling
    /// Optional: whether this Mac's traffic is routed through Loom, and the switch
    /// for it. Supplied by the app (it needs client-layer code the engine can't
    /// depend on); absent in an embedder or a test, where the routing tools then
    /// report honestly that they aren't available.
    private let routing: SystemRoutingControlling?
    private let appVersion: String
    private let group: EventLoopGroup
    private var channel: Channel?
    private let token: String
    /// Which protocol era the requests reaching this endpoint actually spoke. Owned
    /// here rather than by `start()` so a stop/start cycle doesn't reset the tally —
    /// the question it answers ("is anything still on the old revision") is about the
    /// life of the app, not of one listener.
    private let eraLog = MCPEraLog()
    /// Set by `shutdown()`, which is terminal — see its doc comment.
    private var didShutDown = false

    /// This module's only log line (`shutdown()`'s failure path). ProxyCore's `Log`
    /// is internal to that module, so the category is declared here rather than
    /// widening `Log`'s visibility for one call.
    private static let log = Logger(subsystem: "com.loom", category: "mcp")

    public init(
        engine: ProxyControlling,
        appVersion: String,
        token: String = UUID().uuidString,
        routing: SystemRoutingControlling? = nil
    ) {
        self.engine = engine
        self.routing = routing
        self.appVersion = appVersion
        self.token = token
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// Starts the server, writes the handshake file, and returns the bound port.
    ///
    /// `announce: false` skips the handshake — for a second, ephemeral server (a test)
    /// that must not overwrite the running app's `{token, port}`, which is the only
    /// thing telling the `loom-mcp` bridge where the real endpoint is.
    @discardableResult
    public func start(port: Int = 0, announce: Bool = true) async throws -> Int {
        let executor = MCPToolExecutor(
            engine: engine, appVersion: appVersion,
            protocolVersion: Self.protocolVersion, routing: routing, eraLog: eraLog
        )
        let dispatcher = MCPDispatcher(executor: executor, eraLog: eraLog)
        let token = self.token

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // `withPipeliningAssistance: false` on purpose. That handler holds back
                // reads until the current response is written — which means NIO never
                // reads the socket while a request is being served, and so never sees
                // the client's EOF. A blocking tool (`wait_for_flow`) can hold a
                // response for tens of seconds, and a client that gives up in that
                // window must be noticed, not discovered a minute later. Nothing is
                // lost by dropping it: every response says `Connection: close` and
                // closes, so this endpoint never pipelines two requests on one
                // connection (and `MCPHTTPHandler` rejects an attempt to).
                channel.pipeline.configureHTTPServerPipeline(
                    withPipeliningAssistance: false, withErrorHandling: true
                ).flatMap {
                    channel.pipeline.addHandler(MCPHTTPHandler(dispatcher: dispatcher, token: token))
                }
            }

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
        self.channel = channel
        let boundPort = channel.localAddress?.port ?? port
        if announce {
            try HandshakeStore.write(MCPHandshake(token: token, port: boundPort))
        }
        return boundPort
    }

    public func stop() async {
        try? await channel?.close().get()
        channel = nil
    }

    /// Stop the listener **and release the event-loop thread**. Terminal: this server
    /// cannot be started again afterwards.
    ///
    /// `stop()` deliberately keeps the group alive, and for the app that is the whole
    /// story — it owns one server for its entire life. But the group was never shut
    /// down by anything, so every *other* instance cost one permanently running thread
    /// for the rest of the process. That is the same defect `ProxyEngine.shutdown()`
    /// documents, and the test suite is where it bites: this bundle builds a real
    /// server per test, and a channel close racing the next test's bind is exactly the
    /// unattributed ThreadSanitizer report ProxyCore already spent two rounds chasing.
    /// The Thread Sanitizer CI job is scoped to `ProxyCoreTests`, so nothing here would
    /// have caught it.
    ///
    /// Idempotent, and safe to call on a server that was never started.
    public func shutdown() async {
        guard !didShutDown else { return }
        didShutDown = true
        await stop()
        // Never throws in practice for a group nothing else shares; log rather than
        // propagate, since a caller tearing a server down has nothing to do about it.
        do {
            try await group.shutdownGracefully()
        } catch {
            Self.log.error("Event-loop group shutdown failed: \(String(describing: error))")
        }
    }
}

// MARK: - JSON-RPC dispatch

/// Pure JSON-RPC handling, independent of transport. `@unchecked Sendable`
/// because it only holds an immutable executor.
final class MCPDispatcher: @unchecked Sendable {
    private let executor: MCPToolExecutor
    /// Which era each request spoke, and who spoke it. Shared with the executor, so
    /// `get_version` reads back the same tally this writes.
    private let eraLog: MCPEraLog

    init(executor: MCPToolExecutor, eraLog: MCPEraLog) {
        self.executor = executor
        self.eraLog = eraLog
    }

    /// Returns the reply and the HTTP status to send it with, or nil for notifications
    /// (which get 202/no body).
    func handle(requestBody: Data, headers: MCPRequestHeaders = .none) async -> MCPHTTPReply? {
        guard let object = try? JSONSerialization.jsonObject(with: requestBody) else {
            // The era is unknowable when the body won't parse, so this answers with the
            // modern status. A legacy client that sent unparseable JSON is broken either
            // way, and a modern one reads the body before deciding anything.
            return errorReply(id: nil, error: .parseError("invalid JSON"), era: .modern)
        }
        guard let message = object as? [String: Any] else {
            return errorReply(id: nil, error: .invalidRequest("expected a JSON-RPC object"), era: .modern)
        }

        let id = message["id"]
        guard let method = message["method"] as? String else {
            return errorReply(id: id, error: .invalidRequest("missing method"), era: .modern)
        }
        let params = message["params"] as? [String: Any] ?? [:]
        let meta = params["_meta"] as? [String: Any] ?? [:]

        // Notifications carry no id and expect no response.
        if id == nil, method.hasPrefix("notifications/") {
            return nil
        }

        let decision = MCPProtocol.decide(
            method: method, meta: meta, headerVersion: headers.protocolVersion
        )
        let era = decision.era
        // Recorded before dispatch, not after: a request that fails validation still
        // tells us which era it was speaking, and a legacy client whose calls all error
        // is exactly the case the retirement condition must not miss.
        eraLog.record(
            reason: decision.reason,
            // A legacy client names itself in `initialize`'s params; a modern one in
            // `_meta`. Same shape, one parser.
            client: MCPClientIdentity(params["clientInfo"])
                ?? MCPClientIdentity(meta[MCPProtocol.MetaKey.clientInfo])
        )
        do {
            if era == .modern {
                try MCPProtocol.validateModern(
                    method: method, params: params, meta: meta, headers: headers
                )
            }
            let result = try await dispatch(method: method, params: params, era: era)
            return successReply(id: id, result: result, era: era)
        } catch let error as MCPError {
            return errorReply(id: id, error: error, era: era)
        } catch {
            return errorReply(id: id, error: .internalError(error.localizedDescription), era: era)
        }
    }

    private func dispatch(
        method: String, params: [String: Any], era: MCPProtocol.Era
    ) async throws -> [String: Any] {
        switch method {
        // Served in **both** eras, deliberately. The spec requires modern servers to
        // implement it, and answering it even when the request carries no `_meta` is
        // what lets a dual-era client discover that this endpoint speaks 2026-07-28
        // without having to guess-and-retry first.
        case "server/discover":
            return [
                "supportedVersions": MCPProtocol.supported,
                "capabilities": ["tools": ["listChanged": false]],
                "instructions": Self.instructions,
                "ttlMs": MCPProtocol.listTTLMs,
                "cacheScope": MCPProtocol.listCacheScope,
            ]

        // Legacy only: modern has no handshake, so a modern-shaped `initialize` falls
        // through to `methodNotFound` (404) below.
        case "initialize" where era == .legacy:
            // Echo the client's revision when it's one we serve, so it isn't told to
            // speak a version it didn't ask for; otherwise name our newest legacy one.
            let asked = params["protocolVersion"] as? String
            let negotiated = asked.flatMap { MCPProtocol.supported.contains($0) ? $0 : nil }
                ?? MCPProtocol.latestLegacy
            return [
                "protocolVersion": negotiated,
                "serverInfo": ["name": "loom", "version": executor.appVersion],
                "capabilities": ["tools": ["listChanged": false]],
            ]

        case "tools/list":
            guard era == .modern else { return ["tools": executor.toolDefinitions] }
            // Caching hints are mandatory on a modern `complete` list result, and they
            // are the single biggest win in the revision for a client like Claude Code:
            // the registry is static, so re-listing it every turn is pure overhead.
            return [
                "tools": executor.toolDefinitions,
                "ttlMs": MCPProtocol.listTTLMs,
                "cacheScope": MCPProtocol.listCacheScope,
            ]

        case "tools/call":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("missing tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await executor.call(name: name, arguments: arguments)
                return ["content": [["type": "text", "text": text]], "isError": false]
            } catch let failure as MCPToolFailure {
                // Tool ran, failed for a domain reason → in-band error result.
                return ["content": [["type": "text", "text": failure.message]], "isError": true]
            }
            // MCPError (bad params / unknown tool) propagates → JSON-RPC error.

        case "ping":
            return [:]

        default:
            throw MCPError.methodNotFound("unknown method: \(method)")
        }
    }

    /// `instructions` from `server/discover` — the one place the protocol lets a server
    /// say what it is for. Deliberately short: the depth lives in each tool's
    /// description and in the plugin's skill, and this string is paid for on every
    /// discovery.
    private static let instructions = """
    An AI-operable HTTP/HTTPS debugging proxy. Read captured flows, then modify live \
    traffic: replay with overrides, mock/map/rewrite/block with rules, hold requests \
    mid-flight with breakpoints. Write tools are audited and visible to the human \
    supervising from the menu bar.
    """

    // MARK: JSON-RPC envelopes

    private func successReply(id: Any?, result: [String: Any], era: MCPProtocol.Era) -> MCPHTTPReply {
        var result = result
        if era == .modern {
            // Every modern result is polymorphic on `resultType`. Loom never returns
            // `input_required` (no sampling, elicitation or roots — its "waiting"
            // tools park the HTTP request instead), so this is always `complete`.
            result["resultType"] = "complete"
            var meta = result["_meta"] as? [String: Any] ?? [:]
            meta[MCPProtocol.MetaKey.serverInfo] = ["name": "loom", "version": executor.appVersion]
            result["_meta"] = meta
        }
        return MCPHTTPReply(
            statusCode: 200,
            body: envelope(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
        )
    }

    private func errorReply(id: Any?, error: MCPError, era: MCPProtocol.Era) -> MCPHTTPReply {
        var payload: [String: Any] = ["code": error.code, "message": error.message]
        if let data = error.data { payload["data"] = data }
        return MCPHTTPReply(
            // Legacy stays on 200 — that is how every client served here to date has
            // read its JSON-RPC errors, and a status change buys them nothing.
            statusCode: era == .modern ? error.modernStatusCode : 200,
            body: envelope(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": payload])
        )
    }

    private func envelope(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

// MARK: - HTTP transport

// @unchecked Sendable: event-loop confined, no lock. Same contract as ProxyCore's
// handlers — Engine/ProxyCore/CLAUDE.md § Sendable escape hatches — including that
// `inFlight`'s Task must not touch stored properties off the loop (it doesn't).
final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    /// Cap the accumulated request body. Even though the endpoint is loopback +
    /// bearer-gated, any local process can stream at the port; bound it so a hostile
    /// client can't buffer us to death. (A *browser* no longer gets this far — see
    /// the Origin and Content-Type checks in `channelRead` — but a local process
    /// still does.)
    static let maxBodyBytes = 10_000_000

    private let dispatcher: MCPDispatcher
    private let token: String

    private var head: HTTPRequestHead?
    private var body: ByteBuffer?
    /// Set once we've rejected the request at `.head` (bad method/path/auth) or
    /// mid-body (oversize); remaining parts are then ignored.
    private var rejected = false
    /// The task running the current tool call, so closing the connection can cancel
    /// it. Only matters for the blocking tools (`wait_for_flow`, `wait_for_pending`):
    /// a client that gives up or is interrupted mid-wait would otherwise leave a
    /// waiter subscribed and parked for its whole duration with nobody left to answer.
    private var inFlight: Task<Void, Never>?

    init(dispatcher: MCPDispatcher, token: String) {
        self.dispatcher = dispatcher
        self.token = token
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            self.head = head
            body = context.channel.allocator.buffer(capacity: 0)
            rejected = false
            // Validate method / path / auth up front, before buffering any body,
            // so an unauthorized or wrong-path request is rejected immediately.
            if inFlight != nil {
                // A second request on a connection whose first is still being served.
                // Without pipelining assistance we would answer them out of order, so
                // say so instead: every response is `Connection: close`, meaning the
                // client was told not to reuse this connection in the first place.
                reject(channel: context.channel, status: .serviceUnavailable,
                       message: "one request per connection; this endpoint closes after each response")
            } else if Self.path(head.uri) != "/mcp" {
                reject(channel: context.channel, status: .notFound, message: "not found")
            } else if head.method != .POST {
                // `405` specifically, not `404`: GET and DELETE were the old transport's
                // standalone SSE stream and session teardown, and `2026-07-28` requires a
                // server that dropped them to say "method not allowed" so a client can
                // tell that apart from an endpoint that isn't there.
                reject(channel: context.channel, status: .methodNotAllowed,
                       message: "only POST is supported on this endpoint")
            } else if head.headers.contains(name: "Origin") {
                // No legitimate Loom client is a web page. A request carrying Origin
                // came from a browser, which means some site is driving this
                // write-capable endpoint on the user's behalf — refuse it.
                reject(channel: context.channel, status: .forbidden, message: "Origin not accepted")
            } else if !Self.isJSONContentType(head) {
                reject(channel: context.channel, status: .unsupportedMediaType,
                       message: "Content-Type must be application/json")
            } else if !authorized(head) {
                reject(channel: context.channel, status: .unauthorized, message: "unauthorized")
            }
        case var .body(chunk):
            guard !rejected else { return }
            if (body?.readableBytes ?? 0) + chunk.readableBytes > Self.maxBodyBytes {
                reject(channel: context.channel, status: .payloadTooLarge, message: "request body too large")
                return
            }
            body?.writeBuffer(&chunk)
        case .end:
            defer { head = nil; body = nil }
            guard !rejected else { return }
            guard let head else {
                writeJSON(channel: context.channel, status: .badRequest, data: Data(#"{"error":"missing request head"}"#.utf8))
                return
            }
            let payload = body.flatMap { buf in
                buf.getBytes(at: buf.readerIndex, length: buf.readableBytes).map { Data($0) }
            } ?? Data()
            respond(channel: context.channel, head: head, payload: payload)
        }
    }

    /// The path component of a request-target, without any query string.
    private static func path(_ uri: String) -> Substring {
        uri[uri.startIndex ..< (uri.firstIndex(of: "?") ?? uri.endIndex)]
    }

    /// Require `application/json` (a parameter like `; charset=utf-8` is fine).
    ///
    /// This is the load-bearing half of the CSRF defence, and it is load-bearing
    /// precisely because `application/json` is *not* a CORS-safelisted request
    /// content type: a cross-site `fetch` that sets it must pass a preflight, and
    /// this endpoint answers no CORS headers, so the browser never sends the real
    /// request. Without the check, a page could POST `text/plain` — a simple
    /// request, no preflight — and the dispatcher, which never looked at
    /// Content-Type, would parse the body as JSON and run a write tool. The
    /// response is unreadable cross-origin, but the *effect* already happened.
    private static func isJSONContentType(_ head: HTTPRequestHead) -> Bool {
        guard let value = head.headers.first(name: "Content-Type") else { return false }
        let mediaType = value[value.startIndex ..< (value.firstIndex(of: ";") ?? value.endIndex)]
        return mediaType.trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
    }

    private func reject(channel: Channel, status: HTTPResponseStatus, message: String) {
        rejected = true
        writeJSON(channel: channel, status: status, data: Data(#"{"error":"\#(message)"}"#.utf8))
    }

    /// Dispatch off the event loop. A tool call can take a while — a blocking wait
    /// holds for tens of seconds by design — and the loop must stay free to serve
    /// other connections meanwhile, which it does because the `await` happens in this
    /// task rather than on the loop. Each request arrives on its own connection
    /// (`Connection: close`), so nothing queues behind a held one.
    private func respond(channel: Channel, head: HTTPRequestHead, payload: Data) {
        let dispatcher = self.dispatcher
        // `[weak self]`: `Task.isCancelled` is only consulted after `handle` returns,
        // so a strong capture pins this handler and its channel for the rest of a
        // wait that can run tens of seconds — well after the client hung up. Not a
        // leak (the wait is capped), but it outlives its purpose, and everything
        // else in the codebase captures weakly here.
        let headers = MCPRequestHeaders(
            protocolVersion: head.headers.first(name: "MCP-Protocol-Version"),
            method: head.headers.first(name: "Mcp-Method"),
            name: head.headers.first(name: "Mcp-Name")
        )
        inFlight = Task { [weak self] in
            let reply = await dispatcher.handle(requestBody: payload, headers: headers)
            guard !Task.isCancelled, let self else { return }
            if let reply {
                self.writeJSON(
                    channel: channel,
                    status: HTTPResponseStatus(statusCode: reply.statusCode),
                    data: reply.body
                )
            } else {
                self.writeJSON(channel: channel, status: .accepted, data: Data())
            }
        }
    }

    /// The client is gone: stop the work it was waiting for.
    func channelInactive(context: ChannelHandlerContext) {
        inFlight?.cancel()
        inFlight = nil
        context.fireChannelInactive()
    }

    private func authorized(_ head: HTTPRequestHead) -> Bool {
        // The endpoint binds loopback only. A request with no Authorization header
        // is allowed (local trust) so a fixed-URL HTTP client — the Claude Code
        // plugin's MCP — can connect without the per-launch token. When a token IS
        // sent (the loom-mcp stdio bridge), it must still match.
        guard let auth = head.headers.first(name: "Authorization") else { return true }
        return Self.constantTimeEqual(auth, "Bearer \(token)")
    }

    /// Compare in time independent of where the first mismatch is, so a local
    /// attacker can't recover the token byte-by-byte via timing.
    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    private func writeJSON(channel: Channel, status: HTTPResponseStatus, data: Data) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: String(data.count))
        headers.add(name: "Connection", value: "close")
        var writable = channel.allocator.buffer(capacity: data.count)
        writable.writeBytes(data)
        // Frozen for the closure below: `ByteBuffer` is a value type, so this is a
        // copy, not a reference the event loop shares with this frame.
        let buffer = writable
        let responseHead = HTTPResponseHead(version: .http1_1, status: status, headers: headers)

        channel.eventLoop.execute {
            // The typed `write` overloads, not the `NIOAny` ones: `NIOAny` isn't
            // Sendable, and wrapping the parts in it only hides that from the
            // compiler — `HTTPServerResponsePart` itself is Sendable.
            channel.write(HTTPServerResponsePart.head(responseHead), promise: nil)
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
            channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
    }
}
