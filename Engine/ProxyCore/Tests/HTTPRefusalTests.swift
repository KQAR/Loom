import Testing
import Foundation
import NIOCore
import NIOHTTP1
import LoomSharedModels
@testable import LoomProxyCore

/// A request the HTTP proxy port turns away has to be *readable*, not just refused.
///
/// The gap this closes: a client pointed **at** Loom as if Loom were the origin
/// server sends an origin-form request line (`GET /api/users`), which a forward
/// proxy cannot serve. Loom answered `400` on the socket and recorded nothing, so
/// `get_proxy_status` reported a healthy proxy and `get_recent_flows` was empty —
/// identical, over MCP, to a client that never ran. The SOCKS listener already had
/// this right for its own refusals; the HTTP one did not.
@Suite struct HTTPRefusalTests {
    private func head(_ method: HTTPMethod = .GET, uri: String, host: String? = "api.example.com") -> HTTPRequestHead {
        var headers = HTTPHeaders()
        if let host { headers.add(name: "Host", value: host) }
        return HTTPRequestHead(version: .http1_1, method: method, uri: uri, headers: headers)
    }

    // MARK: What the reason says

    @Test func originForm_isExplainedAsAClientAimedAtLoom() {
        let reason = ProxyHandler.refusalReason(for: head(uri: "/api/users"))
        // The three things the operator needs: what arrived, what was expected, and
        // the shape of the fix.
        #expect(reason.contains("origin-form"))
        #expect(reason.contains("GET http://api.example.com/api/users"), "names the absolute form: \(reason)")
        #expect(reason.contains("dev server"), "names the common cause: \(reason)")
        #expect(reason.contains("HTTP_PROXY"), "names the fix: \(reason)")
    }

    @Test func originForm_carriesTheHostSoTheTargetIsKnown() {
        let reason = ProxyHandler.refusalReason(for: head(uri: "/v1/pay", host: "127.0.0.1:5399"))
        #expect(reason.contains("127.0.0.1:5399"))
    }

    @Test func aMissingHostHeader_saysSoRatherThanReadingAsEmpty() {
        let reason = ProxyHandler.refusalReason(for: head(uri: "/api", host: nil))
        #expect(reason.contains("absent"), "got \(reason)")
    }

    /// Garbage and origin-form are different mistakes with different fixes, so they
    /// must not produce the same advice — pointing a client "at Loom as a proxy"
    /// does nothing for a client that sent an unparseable target.
    @Test func aTargetThatIsNeitherFormReadsDifferently() {
        let reason = ProxyHandler.refusalReason(for: head(uri: "api.example.com:443"))
        #expect(reason.contains("neither an absolute URL"))
        #expect(!reason.contains("origin-form —"), "not the origin-form advice: \(reason)")
    }

    /// The reason is built from client-supplied bytes and stored in a log that lives
    /// as long as the process, so a pathological URL must not be copied wholesale.
    @Test func aPathologicalTargetIsClamped() {
        let reason = ProxyHandler.refusalReason(for: head(uri: "/" + String(repeating: "a", count: 5000)))
        #expect(reason.count < 900, "reason grew with the input: \(reason.count) chars")
        #expect(reason.contains("…"))
    }

    // MARK: Reaching the agent

    /// End to end through a real listener: the refusal has to arrive in
    /// `get_proxy_status`, which is the only place an agent can see it.
    @Test func aRefusedRequestIsVisibleInTheStatus() async throws {
        let engine = ProxyEngine(forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore())
        let port = try await engine.start(port: 0, socksPort: 0)
        defer { Task { await engine.stop() } }

        // A unique path, because `RefusalLog.shared` is process-wide and this suite
        // runs in parallel with everything else that records refusals. Asserting on
        // a total would be asserting on test ordering.
        let marker = "/refusal-probe-\(UUID().uuidString)"
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)\(marker)")))
        request.httpMethod = "GET"
        let configuration = URLSessionConfiguration.ephemeral
        // Direct, never proxied: the point is to hit Loom as if it were the origin
        // server, which is exactly what a dev server forwarding to Loom's port does.
        configuration.connectionProxyDictionary = [:]
        let (_, response) = try await URLSession(configuration: configuration).data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 400)

        let status = await engine.status()
        let refusal = try #require(
            status.recentRefusals.first { $0.reason.contains(marker) },
            "the refusal never reached get_proxy_status"
        )
        #expect(refusal.listener == .http, "attributed to the HTTP port, not SOCKS")
        #expect(refusal.peer?.contains("127.0.0.1") == true)
        #expect(status.refusedConnections > 0)
    }

    /// The response body is the *other* reader — whoever ran the client sees only
    /// this — so it carries the same explanation rather than the old bare line.
    @Test func theClientAlsoGetsTheExplanation() async throws {
        let engine = ProxyEngine(forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore())
        let port = try await engine.start(port: 0, socksPort: 0)
        defer { Task { await engine.stop() } }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/api/users"))
        let (data, _) = try await URLSession(configuration: configuration).data(from: url)
        let body = String(decoding: data, as: UTF8.self)
        #expect(body.contains("origin-form"), "got \(body)")
        #expect(body.contains("HTTP_PROXY"), "got \(body)")
    }

    /// A refusal must not leave the exchange half-started: no flow is recorded for a
    /// request that was never forwarded, or the capture would show traffic that
    /// never went anywhere.
    @Test func aRefusedRequestRecordsNoFlow() async throws {
        let engine = ProxyEngine(forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore())
        let port = try await engine.start(port: 0, socksPort: 0)
        defer { Task { await engine.stop() } }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/never-forwarded"))
        _ = try await URLSession(configuration: configuration).data(from: url)

        let flows = await engine.recentFlows(limit: 50)
        #expect(!flows.contains { $0.request.url.contains("never-forwarded") })
    }
}
