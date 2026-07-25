import Testing
import Foundation
import Network
import LoomSharedModels
@testable import MCPServer

/// The blocking tools (`wait_for_flow`, `wait_for_pending`) hold an HTTP request open
/// for as long as tens of seconds. That is only acceptable because of two properties
/// of the transport, and neither is visible from the executor's own tests:
///
/// 1. **A held request doesn't block the server.** The dispatch happens off the
///    single NIO event loop, so other calls are served while one is parked. If this
///    regressed, a wait would freeze the whole MCP surface — including the human's
///    ability to ask what's going on.
/// 2. **A disconnect cancels the work.** A client that gives up (its own timeout, an
///    interrupted turn) closes the connection; the waiter must go away with it
///    instead of sitting subscribed until its deadline with nobody to answer.
@MainActor
@Suite struct MCPServerTransportTests {
    private func startServer(_ engine: StubEngine) async throws -> (server: MCPServer, url: URL) {
        let server = MCPServer(engine: engine, appVersion: "9.9", token: "test-token")
        // `announce: false` — a test must not overwrite the real app's handshake file.
        let port = try await server.start(port: 0, announce: false)
        return (server, try #require(URL(string: "http://127.0.0.1:\(port)/mcp")))
    }

    private func callRequest(_ url: URL, tool: String, arguments: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ])
        return request
    }

    /// Poll for a condition instead of sleeping a fixed time, so the test fails fast
    /// on regression rather than flaking on a slow machine.
    private func eventually(
        _ description: String, timeout: TimeInterval = 3, _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("timed out waiting for: \(description)")
    }

    @Test func aParkedWaitDoesNotBlockOtherCalls() async throws {
        let engine = StubEngine()
        let (server, url) = try await startServer(engine)
        defer { Task { await server.stop() } }

        // Park a 30 s wait. Nothing will ever match it.
        let waiting = Task {
            try? await URLSession.shared.data(for: try self.callRequest(url, tool: "wait_for_flow", arguments: ["max_seconds": 30]))
        }
        await eventually("the wait to subscribe") { engine.flowSubscriptionsOpened > 0 }

        // …and now ask something trivial. It must answer immediately, not queue behind
        // the parked call.
        let started = Date()
        let (data, _) = try await URLSession.shared.data(for: callRequest(url, tool: "get_version", arguments: [:]))
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 3, "a second call took \(elapsed)s while one was parked — the loop is blocked")
        let envelope = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(envelope["result"] != nil)

        waiting.cancel()
    }

    /// Driven over a raw socket rather than `URLSession`: cancelling a URLSession task
    /// doesn't necessarily close the TCP connection (it may hold it for reuse), and
    /// what has to be tested here is the server's reaction to the *connection* going
    /// away, not to a client API call.
    @Test func closingTheConnectionMidWait_cancelsTheWaiter() async throws {
        let engine = StubEngine()
        let server = MCPServer(engine: engine, appVersion: "9.9", token: "test-token")
        let port = try await server.start(port: 0, announce: false)
        defer { Task { await server.stop() } }

        let connection = NWConnection(
            host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: UInt16(port))), using: .tcp
        )
        connection.start(queue: .global())
        connection.send(content: Self.rawCall(tool: "wait_for_flow", arguments: ["max_seconds": 30]),
                        completion: .contentProcessed { _ in })

        await eventually("the wait to subscribe to the flow stream") { engine.flowSubscriptionsOpened > 0 }
        #expect(engine.endedFlowSubscriptions == 0, "precondition: the waiter is still parked")

        // The client gives up — an aborted turn, a client-side timeout, a crash.
        connection.cancel()

        await eventually("the waiter to be torn down with the connection") {
            engine.endedFlowSubscriptions > 0
        }
    }

    /// A complete HTTP/1.1 `tools/call` request as bytes.
    private static func rawCall(tool: String, arguments: [String: Any]) -> Data {
        let body = try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ])
        var request = Data("""
        POST /mcp HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        \r

        """.utf8)
        request.append(body)
        return request
    }
}
