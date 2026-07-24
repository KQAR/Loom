import Testing
import Foundation
import LoomSharedModels
@testable import LoomProxyCore

/// `replay(flow:overrides:)` (issue #40): an embedder that keeps its own store
/// must be able to replay a source flow directly, without it living in Loom's
/// in-memory ring — so replay stops being coupled to the 2000-flow retention.
@Suite struct ReplayFlowTests {
    private func makeEngine() -> (ProxyEngine, ReplayStubUpstream) {
        let upstream = ReplayStubUpstream()
        return (ProxyEngine(forwarder: upstream, caStore: InMemoryCAStore()), upstream)
    }

    private func sourceFlow(url: String = "https://api.example.test/v1/thing") -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: url, headers: [HeaderPair(name: "X-Orig", value: "1")]),
            startedAt: Date(),
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date())
        )
    }

    @Test func replayFlow_sendsAndLinks_withoutStoreLookup() async throws {
        let (engine, upstream) = makeEngine()
        let source = sourceFlow()
        // Deliberately never inserted into the engine's store.

        let replayed = try await engine.replay(flow: source, overrides: .none)

        #expect(upstream.callCount == 1)
        #expect(upstream.lastURL?.absoluteString == source.request.url)
        #expect(replayed.replayedFrom == source.id)
        #expect(replayed.response?.statusCode == 200)
    }

    @Test func replayFlow_appliesOverrides() async throws {
        let (engine, upstream) = makeEngine()
        let source = sourceFlow()

        _ = try await engine.replay(
            flow: source,
            overrides: ReplayOverrides(method: "POST", body: .replace(Data("hi".utf8)))
        )

        #expect(upstream.lastMethod == "POST")
        #expect(upstream.lastBody == Data("hi".utf8))
    }

    @Test func replayByID_stillThrowsWhenAgedOut() async throws {
        let (engine, _) = makeEngine()
        // Nothing in the ring → the id form fails, which is exactly why the flow
        // form exists.
        await #expect(throws: ProxyControlError.self) {
            _ = try await engine.replay(id: UUID(), overrides: .none)
        }
    }
}

private final class ReplayStubUpstream: UpstreamForwarding, @unchecked Sendable {
    var callCount = 0
    var lastMethod: String?
    var lastURL: URL?
    var lastBody: Data?
    var result = ForwardResult(statusCode: 200, headers: [], body: Data("upstream".utf8))

    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        callCount += 1
        lastMethod = method
        lastURL = url
        lastBody = body
        return result
    }
}
