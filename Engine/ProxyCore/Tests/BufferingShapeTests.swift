import Foundation
import Synchronization
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// A rule or a breakpoint holds in memory only what it actually needs — decided per
/// side of the exchange.
///
/// It used to be one decision: anything that touched a body collected the *request*
/// and buffered the *response*. So a response-header rewrite capped every upload
/// through it at `BufferCap`, a block rule failed a large upload instead of answering
/// 403, and a request-phase breakpoint buffered a download nobody would inspect. And
/// the flag that made the decision missed one case outright: a request body replaced
/// from a **file** took the streaming path, which forwards the client's own body, so
/// the rewrite silently never happened.
@Suite("Buffering shape", .timeLimit(.minutes(1)))
struct BufferingShapeTests {
    private let url = URL(string: "https://api.test/upload")!

    private func rules(_ actions: RuleActions) -> RuleApplyingForwarder.BufferShape {
        RuleApplyingForwarder.BufferShape([TrafficRule(name: "r", match: RuleMatch(urlPattern: "*"), actions: actions)])
    }

    private func forwarder(_ actions: RuleActions, base: RecordingUpstream) -> RuleApplyingForwarder {
        RuleApplyingForwarder(
            base: base,
            rules: RulesConfig(state: RulesState(enabled: true, rules: [
                TrafficRule(name: "r", match: RuleMatch(urlPattern: "*"), actions: actions),
            ]), fileURL: nil)
        )
    }

    /// A live request body, the way a client's upload arrives.
    private func upload(_ parts: [String]) -> RequestBody {
        let bridge = RequestBodyBridge(capture: RequestBodyCapture())
        for part in parts { bridge.yield(Data(part.utf8)) }
        bridge.finish()
        return .stream(bridge.chunks, contentLength: nil, trailers: bridge.trailers)
    }

    @Test func aResponseEditLeavesTheUploadStreaming() async throws {
        let base = RecordingUpstream(chunks: ["origin"])
        let rewrite = RuleActions(rewriteResponse: ResponseRewriteAction(setHeaders: [HeaderPair(name: "X-R", value: "1")]))
        let result = try await forwarder(rewrite, base: base).forwardStream(
            method: "POST", url: url, headers: [], body: upload(["a", "b"])
        ).collect()
        #expect(base.sawStreamingBody == true, "the request was collected for a rule that only edits the response")
        #expect(base.receivedBody == Data("ab".utf8))
        #expect(result.headers.value(named: "X-R") == "1", "the response edit still applies")
    }

    /// Past `BufferCap`, so the old collect-then-answer failed it instead of
    /// answering 403.
    @Test func aBlockRuleAnswersAnUploadOfAnySize() async throws {
        let base = RecordingUpstream(chunks: ["origin"])
        let shape = rules(RuleActions(route: .block))
        #expect(!shape.needsOriginalRequestBody)
        let megabyte = String(repeating: "x", count: 1 << 20)
        let parts = Array(repeating: megabyte, count: BufferCap.maxBytes / (1 << 20) + 1)
        let result = try await forwarder(RuleActions(route: .block), base: base).forwardStream(
            method: "POST", url: url, headers: [], body: upload(parts)
        ).collect()
        #expect(result.statusCode == 403)
        #expect(base.calls == 0)
    }

    /// A short-circuit outranks a body substitution: the client's body is never sent,
    /// so there is nothing to substitute into and nothing to buffer.
    @Test func aShortCircuitNeverNeedsTheOriginalBody() {
        let shape = rules(RuleActions(
            route: .block,
            requestSubstitutions: [SubstitutionRule(field: .body, match: "a", replacement: "b")]
        ))
        #expect(!shape.needsOriginalRequestBody)
        #expect(rules(RuleActions(
            requestSubstitutions: [SubstitutionRule(field: .body, match: "a", replacement: "b")]
        )).needsOriginalRequestBody)
    }

    /// The bug the old flag hid: a body replaced from a file went upstream as the
    /// client's own.
    @Test func aBodyReplacedFromAFileIsTheBodySent() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("loom-body-\(UUID())")
        try Data("from file".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let base = RecordingUpstream(chunks: ["origin"])
        let rewrite = RuleActions(rewriteRequest: RequestRewriteAction(body: .file(path: file.path)))
        _ = try await forwarder(rewrite, base: base).forwardStream(
            method: "POST", url: url, headers: [], body: upload(["client"])
        ).collect()
        #expect(base.receivedBody == Data("from file".utf8))
    }

    /// Released from a request-phase hold, the response streams — chunk for chunk,
    /// not folded into one buffered body.
    @Test func aRequestOnlyBreakpointStreamsTheResponse() async throws {
        let base = RecordingUpstream(chunks: ["one", "two", "three"])
        let store = BreakpointStore()
        store.arm(Breakpoint(match: RuleMatch(urlPattern: "*"), onRequest: true))
        let forwarder = BreakpointForwarder(base: base, store: store)

        let stream = forwarder.forwardStream(method: "GET", url: url, headers: [], body: .bytes(nil))
        let resumed = Task {
            for _ in 0 ..< 200 {
                if let held = store.pending().first {
                    _ = store.resume(pendingID: held.id, resolution: .proceed(BreakpointEdit()))
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        var chunks: [String] = []
        for try await event in stream {
            if case let .body(chunk) = event { chunks.append(String(decoding: chunk, as: UTF8.self)) }
        }
        await resumed.value
        #expect(chunks == ["one", "two", "three"])
    }
}

/// Records how the body arrived and answers with `chunks`, one event each.
private final class RecordingUpstream: UpstreamForwarding, Sendable {
    private struct State {
        var calls = 0
        var sawStreamingBody: Bool?
        var receivedBody: Data?
    }
    private let state = Mutex(State())
    private let chunks: [String]

    init(chunks: [String]) { self.chunks = chunks }

    var calls: Int { state.withLock { $0.calls } }
    var sawStreamingBody: Bool? { state.withLock { $0.sawStreamingBody } }
    var receivedBody: Data? { state.withLock { $0.receivedBody } }

    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        try await forwardStream(method: method, url: url, headers: headers, body: .bytes(body)).collect()
    }

    func forwardStream(method: String, url: URL, headers: [HeaderPair], body: RequestBody) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
        let chunks = chunks
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                let streaming: Bool
                if case .stream = body.source { streaming = true } else { streaming = false }
                let collected = try? await body.collect()
                self.state.withLock {
                    $0.calls += 1
                    $0.sawStreamingBody = streaming
                    $0.receivedBody = collected?.body
                }
                continuation.yield(.head(statusCode: 200, httpVersion: nil, headers: []))
                for chunk in chunks { continuation.yield(.body(Data(chunk.utf8))) }
                continuation.yield(.end(trailers: nil))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
