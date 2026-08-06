import Testing
import Foundation
import NIOCore
import NIOHTTP1
import LoomSharedModels
@testable import LoomProxyCore

/// A reverse-proxy endpoint: a local port that stands in for one upstream origin, so
/// a client that cannot be pointed at a proxy is still captured.
///
/// The case that motivated it: Node's global `fetch`/undici ignores `HTTP_PROXY`, so a
/// dev server forwarding `/api` to a backend is invisible however the environment is
/// set. Measured, same process and same env — axios captured, `fetch` not. An endpoint
/// removes the client's cooperation from the equation.
@Suite struct ReverseProxyTests {
    private func makeEngine(_ forwarder: StubForwarder) -> ProxyEngine {
        ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())
    }

    private func directSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // Never proxied: the point is to reach the endpoint as if it were the server.
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }

    // MARK: URL synthesis — where the traffic actually goes

    @Test func theUpstreamURLIsOriginPlusRequestTarget() throws {
        let endpoint = ReverseProxyEndpoint(upstream: "https://api.example.com")
        #expect(endpoint.forwardURL(requestTarget: "/users?page=2")?.absoluteString == "https://api.example.com/users?page=2")
    }

    /// A base path on the upstream is prefixed, not replaced — `/v2` + `/users` is how
    /// a versioned backend is reached without rewriting every client path.
    @Test func aBasePathOnTheUpstreamIsPrefixed() {
        let endpoint = ReverseProxyEndpoint(upstream: "https://api.example.com/v2")
        #expect(endpoint.forwardURL(requestTarget: "/users")?.absoluteString == "https://api.example.com/v2/users")
    }

    @Test func aQueryContainingAQuestionMarkIsNotSplitTwice() {
        let endpoint = ReverseProxyEndpoint(upstream: "http://api.example.com")
        let url = endpoint.forwardURL(requestTarget: "/search?q=a?b&n=1")
        #expect(url?.absoluteString == "http://api.example.com/search?q=a?b&n=1")
    }

    // MARK: Validation happens at create time

    @Test func aBareHostIsRejectedWithTheReasonWhy() async {
        let engine = makeEngine(StubForwarder(status: 200, body: Data()))
        await #expect(throws: ProxyControlError.self) {
            _ = try await engine.createReverseProxy(ReverseProxyEndpoint(upstream: "api.example.com"))
        }

        await engine.stopForTest()
    }

    @Test func anUpstreamWithAQueryIsRejected() async {
        // Silently dropping it would misreport what Loom forwards.
        await #expect(throws: ProxyControlError.self) {
            _ = try ReverseProxyEndpoint.normalizedUpstream("https://api.example.com/?env=staging")
        }
    }

    @Test func aTrailingSlashIsNormalizedAwaySoPathsDoNotDouble() throws {
        #expect(try ReverseProxyEndpoint.normalizedUpstream("https://api.example.com/") == "https://api.example.com")
        let endpoint = ReverseProxyEndpoint(upstream: try ReverseProxyEndpoint.normalizedUpstream("https://api.example.com/v2/"))
        #expect(endpoint.forwardURL(requestTarget: "/users")?.absoluteString == "https://api.example.com/v2/users")
    }

    /// Binding Loom's own proxy port would shadow the proxy — "works" in the worst way.
    @Test func loomsOwnPortsAreRefused() async throws {
        let engine = makeEngine(StubForwarder(status: 200, body: Data()))
        let port = try await engine.start(port: 0, socksPort: 0)
        await #expect(throws: ProxyControlError.self) {
            _ = try await engine.createReverseProxy(
                ReverseProxyEndpoint(requestedPort: port, upstream: "https://api.example.com"))
        }
        await engine.stopForTest()
    }

    // MARK: Forwarding and capture

    @Test func aRequestToTheEndpointIsForwardedToTheUpstream() async throws {
        let forwarder = StubForwarder(status: 200, body: Data("{}".utf8))
        let engine = makeEngine(forwarder)
        _ = try await engine.start(port: 0, socksPort: 0)

        let status = try await engine.createReverseProxy(ReverseProxyEndpoint(upstream: "https://api.example.com"))
        let local = try #require(status.localURL)
        let (_, response) = try await directSession().data(from: try #require(URL(string: "\(local)/users?page=2")))

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(forwarder.lastURL?.absoluteString == "https://api.example.com/users?page=2")
        await engine.stopForTest()
    }

    /// The flow must record the **upstream** URL. If `127.0.0.1:port` leaked in here,
    /// every rule and breakpoint an agent wrote against the real host would silently
    /// stop matching traffic that arrived this way.
    @Test func theCapturedFlowCarriesTheUpstreamURL() async throws {
        let engine = makeEngine(StubForwarder(status: 201, body: Data()))
        _ = try await engine.start(port: 0, socksPort: 0)

        let status = try await engine.createReverseProxy(ReverseProxyEndpoint(upstream: "https://api.example.com"))
        let local = try #require(status.localURL)
        _ = try await directSession().data(from: try #require(URL(string: "\(local)/orders")))

        let captured = try #require(
            await awaitFlow(from: engine) { $0.request.url.contains("/orders") },
            "nothing was captured for the reverse-proxied request"
        )
        #expect(captured.request.url == "https://api.example.com/orders")
        #expect(!captured.request.url.contains("127.0.0.1"))
        await engine.stopForTest()
    }

    /// Default: the client's `Host` (127.0.0.1:port) is dropped so the forwarder
    /// synthesizes the upstream's. Sending a real server `Host: 127.0.0.1` gets a 404
    /// that reads like Loom broke the request.
    @Test func theHostHeaderFollowsTheUpstreamByDefault() async throws {
        let forwarder = StubForwarder(status: 200, body: Data())
        let engine = makeEngine(forwarder)
        _ = try await engine.start(port: 0, socksPort: 0)

        let status = try await engine.createReverseProxy(ReverseProxyEndpoint(upstream: "https://api.example.com"))
        let local = try #require(status.localURL)
        _ = try await directSession().data(from: try #require(URL(string: "\(local)/ping")))

        let flow = await awaitFlow(from: engine) { $0.request.url.contains("/ping") }
        let headers = try #require(flow?.request.headers)
        let host = headers.first { $0.name.lowercased() == "host" }
        #expect(host == nil, "the loopback Host should not be forwarded: \(String(describing: host))")
        await engine.stopForTest()
    }

    @Test func keepHostHeaderPreservesTheClientsHost() async throws {
        let engine = makeEngine(StubForwarder(status: 200, body: Data()))
        _ = try await engine.start(port: 0, socksPort: 0)

        let status = try await engine.createReverseProxy(
            ReverseProxyEndpoint(upstream: "https://api.example.com", keepHostHeader: true))
        let local = try #require(status.localURL)
        _ = try await directSession().data(from: try #require(URL(string: "\(local)/keep")))

        let flow = await awaitFlow(from: engine) { $0.request.url.contains("/keep") }
        let headers = try #require(flow?.request.headers)
        #expect(headers.contains { $0.name.lowercased() == "host" && $0.value.contains("127.0.0.1") })
        await engine.stopForTest()
    }

    // MARK: Lifecycle

    @Test func deletingAnEndpointClosesItsPort() async throws {
        let engine = makeEngine(StubForwarder(status: 200, body: Data()))
        _ = try await engine.start(port: 0, socksPort: 0)

        let status = try await engine.createReverseProxy(ReverseProxyEndpoint(upstream: "https://api.example.com"))
        try await engine.deleteReverseProxy(id: status.endpoint.id)
        #expect(await engine.reverseProxies().isEmpty)

        // The socket has to be gone, not just the config entry: a listener outliving
        // its entry would keep capturing for an endpoint nothing can see or delete.
        let local = try #require(status.localURL)
        await #expect(throws: (any Error).self) {
            _ = try await self.directSession().data(from: try #require(URL(string: "\(local)/after-delete")))
        }
        await engine.stopForTest()
    }

    @Test func deletingAnUnknownEndpointThrows() async {
        let engine = makeEngine(StubForwarder(status: 200, body: Data()))
        await #expect(throws: ProxyControlError.self) {
            try await engine.deleteReverseProxy(id: UUID())
        }

        await engine.stopForTest()
    }

    @Test func stoppingTheEngineClearsBindStateButKeepsTheEndpoint() async throws {
        let engine = makeEngine(StubForwarder(status: 200, body: Data()))
        _ = try await engine.start(port: 0, socksPort: 0)
        let created = try await engine.createReverseProxy(ReverseProxyEndpoint(upstream: "https://api.example.com"))
        await engine.stop()

        let after = await engine.reverseProxies()
        // Still configured (a dev server's config file still names it), but honestly
        // reported as not listening rather than advertising a dead port.
        #expect(after.count == 1)
        #expect(after.first?.endpoint.id == created.endpoint.id)
        #expect(after.first?.isListening == false)
        #expect(after.first?.localURL == nil)
        await engine.stopForTest()
    }

    // MARK: It is not a proxy port

    @Test func aConnectRequestIsRefusedWithAnExplanation() {
        let endpoint = ReverseProxyEndpoint(upstream: "https://api.example.com")
        let head = HTTPRequestHead(version: .http1_1, method: .CONNECT, uri: "api.example.com:443")
        let reason = ProxyHandler.refusalReason(for: head, reverseUpstream: endpoint)
        #expect(reason.contains("Reverse-proxy endpoint refused"))
        #expect(reason.contains("not as a proxy"))
        // The forward port's advice would be actively wrong here — a client on this
        // port is supposed to send origin-form.
        #expect(!reason.contains("origin-form —"), "got \(reason)")
    }

    /// A client that sends absolute-form to a reverse endpoint is still talking to
    /// *that* endpoint. Honoring its URL would route past the upstream the endpoint
    /// exists to reach — the one thing a reverse proxy must not do.
    @Test func anAbsoluteFormRequestStillGoesToTheConfiguredUpstream() async throws {
        let forwarder = StubForwarder(status: 200, body: Data())
        let engine = makeEngine(forwarder)
        _ = try await engine.start(port: 0, socksPort: 0)
        let status = try await engine.createReverseProxy(ReverseProxyEndpoint(upstream: "https://api.example.com"))
        let port = try #require(status.boundPort)

        // Hand-written absolute-form request line — no HTTP client will send this to a
        // server, so it goes on the wire directly.
        let raw = "GET http://evil.example.com/steal HTTP/1.1\r\nHost: evil.example.com\r\nConnection: close\r\n\r\n"
        try await Self.sendRaw(raw, toPort: port)

        var seen: URL?
        for _ in 0 ..< 100 where seen == nil {
            seen = forwarder.lastURL
            if seen == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        #expect(seen?.absoluteString == "https://api.example.com/steal", "got \(String(describing: seen))")
        await engine.stopForTest()
    }

    // MARK: WebSocket through an endpoint

    /// The upgrade's upstream routing comes from the resolved URL's scheme. On a
    /// reverse endpoint that scheme is the configured upstream's `http`/`https` —
    /// matching on the literal `wss` alone sent an `https` upstream's upgrade as
    /// plaintext to port 80.
    @Test func webSocketRoutingCountsBothSpellingsOfTLS() throws {
        func routing(_ s: String) throws -> (port: Int, tls: Bool) {
            ProxyHandler.webSocketRouting(for: try #require(URL(string: s)))
        }
        #expect(try routing("https://api.example.com/socket") == (443, true))
        #expect(try routing("wss://api.example.com/socket") == (443, true))
        #expect(try routing("http://127.0.0.1:3862/hmr") == (3862, false))
        #expect(try routing("ws://127.0.0.1:3862/hmr") == (3862, false))
        #expect(try routing("https://api.example.com:8443/socket") == (8443, true))
    }

    /// End to end: a client that can't be pointed at a proxy (a dev server's HMR
    /// socket) upgrades through the endpoint, frames splice both ways, and the
    /// exchange lands as one flow carrying the upstream URL and the frames.
    @Test func aWebSocketUpgradeThroughAnEndpointIsSplicedAndCaptured() async throws {
        let upstreamPort = try Self.startWebSocketEchoUpstream()
        let engine = makeEngine(StubForwarder(status: 200, body: Data()))
        _ = try await engine.start(port: 0, socksPort: 0)
        let status = try await engine.createReverseProxy(
            ReverseProxyEndpoint(upstream: "http://127.0.0.1:\(upstreamPort)"))
        let endpointPort = try #require(status.boundPort)

        let echoed = try await Self.driveWebSocketClient(port: endpointPort, path: "/hmr")
        #expect(echoed == "pong")

        let flow = try #require(
            await awaitFlow(from: engine) { flow in
                flow.isWebSocket && (flow.webSocketMessages?.count ?? 0) >= 2
            },
            "no WebSocket flow captured through the reverse endpoint"
        )
        #expect(flow.request.url == "http://127.0.0.1:\(upstreamPort)/hmr")
        let messages = try #require(flow.webSocketMessages)
        #expect(messages.contains { $0.direction == .clientToServer && $0.textPayload == "ping" })
        #expect(messages.contains { $0.direction == .serverToClient && $0.textPayload == "pong" })
        await engine.stopForTest()
    }

    // MARK: Persistence

    @Test func endpointsSurviveARelaunch() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-reverse-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let config = ReverseProxyConfig(fileURL: file)
        let endpoint = ReverseProxyEndpoint(requestedPort: 9200, upstream: "https://api.example.com", label: "checkout")
        config.upsert(endpoint)
        config.flush()

        // A dev server's config file still names port 9200 after Loom restarts, so the
        // endpoint has to come back or the developer's setup breaks silently.
        let reloaded = ReverseProxyConfig(fileURL: file)
        let all = reloaded.all()
        #expect(all.count == 1)
        #expect(all.first?.requestedPort == 9200)
        #expect(all.first?.upstream == "https://api.example.com")
        #expect(all.first?.label == "checkout")
    }

    @Test func bindStateIsNotPersisted() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-reverse-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let config = ReverseProxyConfig(fileURL: file)
        let endpoint = ReverseProxyEndpoint(requestedPort: 9201, upstream: "https://api.example.com")
        config.upsert(endpoint)
        config.noteBound(id: endpoint.id, port: 9201)
        config.flush()

        // Where it was listening is a fact about the previous run; a persisted one
        // would have a fresh launch claim a port nothing is bound to.
        let reloaded = ReverseProxyConfig(fileURL: file)
        #expect(reloaded.snapshot().first?.isListening == false)
    }

    @Test func aFailedBindIsRecordedAgainstTheEndpoint() throws {
        let config = ReverseProxyConfig(fileURL: nil)
        let endpoint = ReverseProxyEndpoint(requestedPort: 9202, upstream: "https://api.example.com")
        config.upsert(endpoint)
        config.noteFailure(id: endpoint.id, error: "address already in use")

        // "Configured but not listening" is what a client experiences as connection
        // refused, so the reason has to be readable rather than dropped.
        let status = try #require(config.snapshot().first)
        #expect(status.isListening == false)
        #expect(status.error?.contains("already in use") == true)
    }

    // MARK: - WebSocket upstream + client

    /// Minimal one-shot WebSocket upstream: accepts a single connection, answers
    /// the upgrade with a canned 101, replies to the client's first frame with an
    /// unmasked text frame "pong", then closes. Returns the bound port.
    private static func startWebSocketEchoUpstream() throws -> Int {
        let server = socket(AF_INET, SOCK_STREAM, 0)
        guard server >= 0 else { throw ProxyControlError.invalidReverseProxy("socket() failed") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(server, 1) == 0 else {
            close(server)
            throw ProxyControlError.invalidReverseProxy("bind()/listen() failed")
        }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(server, $0, &length)
            }
        }
        let port = Int(UInt16(bigEndian: boundAddress.sin_port))

        DispatchQueue(label: "loom.reverse.ws-upstream").async {
            defer { close(server) }
            let conn = accept(server, nil, nil)
            guard conn >= 0 else { return }
            defer { close(conn) }
            // Read the upgrade request through its blank line.
            var request = [UInt8]()
            var scratch = [UInt8](repeating: 0, count: 4096)
            while !request.suffix(4).elementsEqual([0x0D, 0x0A, 0x0D, 0x0A]) {
                let count = read(conn, &scratch, scratch.count)
                guard count > 0 else { return }
                request.append(contentsOf: scratch[0 ..< count])
            }
            // Canned 101 — the test's own client doesn't validate the accept key.
            let handshake = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                + "Connection: Upgrade\r\nSec-WebSocket-Accept: loom-test\r\n\r\n"
            _ = Array(handshake.utf8).withUnsafeBufferPointer { write(conn, $0.baseAddress, $0.count) }
            // Wait for the client's frame (relayed through Loom), answer with an
            // unmasked text frame "pong", then close — which ends the splice.
            guard read(conn, &scratch, scratch.count) > 0 else { return }
            let pong: [UInt8] = [0x81, 0x04] + Array("pong".utf8)
            _ = pong.withUnsafeBufferPointer { write(conn, $0.baseAddress, $0.count) }
        }
        return port
    }

    /// Speak just enough WebSocket at the endpoint: origin-form upgrade, one
    /// masked text frame "ping", then return the text of the frame that comes back.
    private static func driveWebSocketClient(port: Int, path: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            DispatchQueue(label: "loom.reverse.ws-client").async {
                do {
                    let sock = socket(AF_INET, SOCK_STREAM, 0)
                    guard sock >= 0 else { throw ProxyControlError.invalidReverseProxy("socket() failed") }
                    defer { close(sock) }
                    var address = sockaddr_in()
                    address.sin_family = sa_family_t(AF_INET)
                    address.sin_port = in_port_t(UInt16(port).bigEndian)
                    address.sin_addr.s_addr = inet_addr("127.0.0.1")
                    let connected = withUnsafePointer(to: &address) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    guard connected == 0 else { throw ProxyControlError.invalidReverseProxy("connect() failed") }
                    let upgrade = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
                        + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                        + "Sec-WebSocket-Key: bG9vbS1zbW9rZS10ZXN0LWtleQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
                    _ = Array(upgrade.utf8).withUnsafeBufferPointer { write(sock, $0.baseAddress, $0.count) }
                    // Read through the 101's blank line.
                    var response = [UInt8]()
                    var scratch = [UInt8](repeating: 0, count: 4096)
                    while !response.suffix(4).elementsEqual([0x0D, 0x0A, 0x0D, 0x0A]) {
                        let count = read(sock, &scratch, scratch.count)
                        guard count > 0 else { throw ProxyControlError.invalidReverseProxy("connection closed before 101") }
                        response.append(contentsOf: scratch[0 ..< count])
                    }
                    guard String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 101") else {
                        throw ProxyControlError.invalidReverseProxy("expected 101, got \(String(decoding: response.prefix(64), as: UTF8.self))")
                    }
                    // One masked text frame "ping" (clients must mask, RFC 6455 §5.1).
                    let mask: [UInt8] = [0x10, 0x20, 0x30, 0x40]
                    let payload = Array("ping".utf8)
                    let frame: [UInt8] = [0x81, 0x80 | UInt8(payload.count)] + mask
                        + payload.enumerated().map { $1 ^ mask[$0 % 4] }
                    _ = frame.withUnsafeBufferPointer { write(sock, $0.baseAddress, $0.count) }
                    // The upstream's unmasked reply: 2-byte header + payload.
                    var reply = [UInt8]()
                    while reply.count < 6 {
                        let count = read(sock, &scratch, scratch.count)
                        guard count > 0 else { break }
                        reply.append(contentsOf: scratch[0 ..< count])
                    }
                    guard reply.count >= 6 else { throw ProxyControlError.invalidReverseProxy("no echo frame relayed back") }
                    continuation.resume(returning: String(decoding: reply[2 ..< 2 + Int(reply[1] & 0x7F)], as: UTF8.self))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Raw client

    /// Write one hand-crafted request and wait for the connection to close.
    private static func sendRaw(_ request: String, toPort port: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let queue = DispatchQueue(label: "loom.reverse.raw")
            queue.async {
                let socket = socket(AF_INET, SOCK_STREAM, 0)
                guard socket >= 0 else {
                    continuation.resume(throwing: ProxyControlError.invalidReverseProxy("socket() failed"))
                    return
                }
                defer { close(socket) }
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = in_port_t(UInt16(port).bigEndian)
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                let connected = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard connected == 0 else {
                    continuation.resume(throwing: ProxyControlError.invalidReverseProxy("connect() failed"))
                    return
                }
                let bytes = Array(request.utf8)
                _ = bytes.withUnsafeBufferPointer { write(socket, $0.baseAddress, $0.count) }
                var scratch = [UInt8](repeating: 0, count: 1024)
                while read(socket, &scratch, scratch.count) > 0 {}
                continuation.resume()
            }
        }
    }
}
