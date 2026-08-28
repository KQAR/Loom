import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// The upstream leg of a `wss://` splice, and what happens when it can't be set up.
///
/// Both cases here were silent before. `WebSocketRelay` built its upstream TLS handler
/// with `try?` and fell through to "no handler" — which is not "no TLS attempted", it
/// is plaintext bytes written at a TLS server on a connection the client asked to be
/// encrypted. And a splice that failed before it started recorded nothing at all.
@Suite("WebSocket upstream TLS", .timeLimit(.minutes(1)))
struct WebSocketUpstreamTLSTests {
    // MARK: The silent downgrade

    /// The reachable instance of the swallowed error: `NIOSSLClientHandler` refuses an
    /// IP literal as an SNI server name (`cannotUseIPAddressInSNI`), so every
    /// `wss://<ip>:port/` — a LAN device, a dev server addressed by IP — threw here and
    /// was downgraded to plaintext. It must build a handler instead.
    @Test func ipLiteralOrigin_buildsATLSHandler_ratherThanThrowingAndBeingSkipped() throws {
        _ = try WebSocketRelay.makeSSLHandler(host: "127.0.0.1")
        _ = try WebSocketRelay.makeSSLHandler(host: "::1")
    }

    @Test func namedOrigin_stillBuildsATLSHandler() throws {
        _ = try WebSocketRelay.makeSSLHandler(host: "echo.example.test")
    }

    /// The relay and the forwarder must decide "is this an SNI-able name" the same way;
    /// they disagreed, which is how only one of them carried the bug. One definition now.
    @Test func isIPLiteral_recognizesV4AndV6ButNotNames() {
        #expect(SharedTLS.isIPLiteral("127.0.0.1"))
        #expect(SharedTLS.isIPLiteral("192.168.1.10"))
        #expect(SharedTLS.isIPLiteral("::1"))
        #expect(SharedTLS.isIPLiteral("fe80::1"))
        #expect(!SharedTLS.isIPLiteral("example.test"))
        #expect(!SharedTLS.isIPLiteral("127.0.0.1.example.test"))
        #expect(!SharedTLS.isIPLiteral(""))
    }

    // MARK: The invisible failure

    /// An upgrade that never reaches its origin must still be a flow. The splice path
    /// creates its capture sink only on success, so this used to leave the client with
    /// a fixed 502 and leave `get_recent_flows` — and the Inspector — with nothing,
    /// which reads exactly like a client that never ran.
    @Test func anUpgradeThatCannotReachItsOrigin_isRecordedAsAFailedFlow() async throws {
        let engine = ProxyEngine(forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore())
        let port = try await engine.start(port: 0)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownBlocking(group) }

        // Port 1 on loopback: reserved, nothing listens, connect fails fast.
        let deadOrigin = "http://127.0.0.1:1/socket"
        let client = try await ClientBootstrap(group: group)
            .connect(host: "127.0.0.1", port: port).get()
        defer { client.close(promise: nil) }

        var buffer = client.allocator.buffer(capacity: 256)
        buffer.writeString("""
        GET \(deadOrigin) HTTP/1.1\r
        Host: 127.0.0.1:1\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Version: 13\r
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
        \r

        """)
        try await client.writeAndFlush(buffer).get()

        // Waits for the *settled* record, not the first one to appear. A request is
        // recorded when its head is parsed and the failure lands afterwards, so
        // matching on the URL alone can catch the pending version — which is a real
        // intermediate state, not a defect, and made this test fail intermittently
        // under Thread Sanitizer, where the two are further apart.
        let flow = try #require(
            await awaitFlow(from: engine) {
                $0.request.url.contains("127.0.0.1:1/socket") && $0.error != nil
            },
            "a WebSocket upgrade that never reached its origin must still be captured, carrying why"
        )
        #expect(flow.error != nil, "the flow must carry why the splice never started")
        await engine.stopForTest()
    }
}
