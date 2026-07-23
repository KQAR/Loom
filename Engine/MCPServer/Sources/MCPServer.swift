import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import SharedModels

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

    var code: Int {
        switch self {
        case .parseError: return -32_700
        case .invalidRequest: return -32_600
        case .methodNotFound: return -32_601
        case .invalidParams: return -32_602
        case .internalError: return -32_603
        }
    }

    var message: String {
        switch self {
        case let .parseError(m), let .invalidRequest(m), let .methodNotFound(m),
             let .invalidParams(m), let .internalError(m):
            return m
        }
    }
}

/// A local HTTP JSON-RPC endpoint (`POST /mcp`) implementing the slice of MCP
/// that the stdio bridge forwards: initialize, tools/list, tools/call.
///
/// `@unchecked Sendable` so the app (Swift 6) can hand the boot-time instance to
/// its `start()` task without a data-race diagnostic (Xcode 26.5 promotes that to
/// an error). Safe in practice: `engine`/`appVersion`/`token` are immutable, the
/// `EventLoopGroup` is thread-safe, and `channel` is written once at boot. Matches
/// the `@unchecked Sendable` treatment of `MCPDispatcher`/`MCPHTTPHandler`.
public final class MCPServer: @unchecked Sendable {
    public static let protocolVersion = "2025-06-18"

    private let engine: ProxyControlling
    private let appVersion: String
    private let group: EventLoopGroup
    private var channel: Channel?
    private let token: String

    public init(engine: ProxyControlling, appVersion: String, token: String = UUID().uuidString) {
        self.engine = engine
        self.appVersion = appVersion
        self.token = token
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// Starts the server, writes the handshake file, and returns the bound port.
    @discardableResult
    public func start(port: Int = 0) async throws -> Int {
        let executor = MCPToolExecutor(engine: engine, appVersion: appVersion, protocolVersion: Self.protocolVersion)
        let dispatcher = MCPDispatcher(executor: executor)
        let token = self.token

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(MCPHTTPHandler(dispatcher: dispatcher, token: token))
                }
            }

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
        self.channel = channel
        let boundPort = channel.localAddress?.port ?? port
        try HandshakeStore.write(MCPHandshake(token: token, port: boundPort))
        return boundPort
    }

    public func stop() async {
        try? await channel?.close().get()
        channel = nil
    }
}

// MARK: - JSON-RPC dispatch

/// Pure JSON-RPC handling, independent of transport. `@unchecked Sendable`
/// because it only holds an immutable executor.
final class MCPDispatcher: @unchecked Sendable {
    private let executor: MCPToolExecutor

    init(executor: MCPToolExecutor) {
        self.executor = executor
    }

    /// Returns response bytes, or nil for notifications (which get 202/no body).
    func handle(requestBody: Data) async -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: requestBody) else {
            return errorResponse(id: nil, error: .parseError("invalid JSON"))
        }
        guard let message = object as? [String: Any] else {
            return errorResponse(id: nil, error: .invalidRequest("expected a JSON-RPC object"))
        }

        let id = message["id"]
        guard let method = message["method"] as? String else {
            return errorResponse(id: id, error: .invalidRequest("missing method"))
        }
        let params = message["params"] as? [String: Any] ?? [:]

        // Notifications carry no id and expect no response.
        if id == nil, method.hasPrefix("notifications/") {
            return nil
        }

        do {
            let result = try await dispatch(method: method, params: params)
            return successResponse(id: id, result: result)
        } catch let error as MCPError {
            return errorResponse(id: id, error: error)
        } catch {
            return errorResponse(id: id, error: .internalError(error.localizedDescription))
        }
    }

    private func dispatch(method: String, params: [String: Any]) async throws -> Any {
        switch method {
        case "initialize":
            return [
                "protocolVersion": MCPServer.protocolVersion,
                "serverInfo": ["name": "loom", "version": executor.appVersion],
                "capabilities": ["tools": ["listChanged": false]],
            ]

        case "tools/list":
            return ["tools": executor.toolDefinitions]

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

    // MARK: JSON-RPC envelopes

    private func successResponse(id: Any?, result: Any) -> Data {
        envelope(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func errorResponse(id: Any?, error: MCPError) -> Data {
        envelope([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": error.code, "message": error.message],
        ])
    }

    private func envelope(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

// MARK: - HTTP transport

final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    /// Cap the accumulated request body. Even though the endpoint is loopback +
    /// bearer-gated, any local process (or a browser via a no-preflight POST) can
    /// stream at the port; bound it so a hostile client can't buffer us to death.
    static let maxBodyBytes = 10_000_000

    private let dispatcher: MCPDispatcher
    private let token: String

    private var head: HTTPRequestHead?
    private var body: ByteBuffer?
    /// Set once we've rejected the request at `.head` (bad method/path/auth) or
    /// mid-body (oversize); remaining parts are then ignored.
    private var rejected = false

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
            if head.method != .POST || Self.path(head.uri) != "/mcp" {
                reject(channel: context.channel, status: .notFound, message: "not found")
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

    private func reject(channel: Channel, status: HTTPResponseStatus, message: String) {
        rejected = true
        writeJSON(channel: channel, status: status, data: Data(#"{"error":"\#(message)"}"#.utf8))
    }

    private func respond(channel: Channel, head: HTTPRequestHead, payload: Data) {
        let dispatcher = self.dispatcher
        Task {
            let response = await dispatcher.handle(requestBody: payload)
            if let response {
                self.writeJSON(channel: channel, status: .ok, data: response)
            } else {
                self.writeJSON(channel: channel, status: .accepted, data: Data())
            }
        }
    }

    private func authorized(_ head: HTTPRequestHead) -> Bool {
        guard let auth = head.headers.first(name: "Authorization") else { return false }
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
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let responseHead = HTTPResponseHead(version: .http1_1, status: status, headers: headers)

        channel.eventLoop.execute {
            channel.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
            channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
    }
}
