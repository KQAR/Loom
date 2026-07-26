import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// A client that disappears mid-upload must fail the in-flight request-body stream.
///
/// This is not cosmetic. The bridge's `NIOThrowingAsyncSequenceProducer.Source` is
/// created with `finishOnDeinit: false`, so a Source that deinits without being
/// finished hits a `preconditionFailure` inside NIOCore — an aborted upload would
/// take the whole process down. Both request handlers own a bridge and both must
/// terminate it from `channelInactive` / `errorCaught`.
///
/// Real sockets on purpose: the exchange runs on a `Task` and writes back from that
/// thread, which an `EmbeddedChannel` may not be touched from.
@Suite("Aborted request bodies", .timeLimit(.minutes(1)))
struct AbortedRequestBodyTests {
    /// Plain-HTTP path (`ProxyHandler`), through the real engine.
    @Test func closingMidBodyFailsThePlainHTTPStream() async throws {
        let forwarder = BodyStreamRecorder()
        let engine = ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())
        let port = try await engine.start(port: 0)
        defer { Task { await engine.stop() } }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let client = try await ClientBootstrap(group: group)
            .connect(host: "127.0.0.1", port: port).get()
        var buffer = client.allocator.buffer(capacity: 256)
        // Promise 1000 bytes, send 100, then vanish.
        buffer.writeString("POST http://example.test/upload HTTP/1.1\r\nHost: example.test\r\n")
        buffer.writeString("Content-Length: 1000\r\n\r\n")
        buffer.writeString(String(repeating: "A", count: 100))
        try await client.writeAndFlush(buffer).get()
        try await client.close().get()

        let error = try #require(await forwarder.awaitFailure(), "the body stream should fail, not hang or finish")
        #expect(error is RequestBodyAborted, "got \(error)")
    }

    /// MITM path (`TLSInterceptHandler`). Driven over a plain socket with the same
    /// HTTP framing the handler sees after TLS termination — the handler is what's
    /// under test, not the TLS below it.
    @Test func closingMidBodyFailsTheInterceptedStream() async throws {
        let forwarder = BodyStreamRecorder()
        let store = FlowStore()

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let pipeline = channel.pipeline
                return pipeline.addHandler(HTTPResponseEncoder(), name: "loom.mitm.encoder")
                    .flatMap {
                        pipeline.addHandler(
                            ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                            name: "loom.mitm.decoder"
                        )
                    }
                    .flatMap {
                        pipeline.addHandler(
                            TLSInterceptHandler(host: "example.test", port: 443, store: store, forwarder: forwarder),
                            name: "loom.mitm.intercept"
                        )
                    }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { try? server.close().wait() }

        let client = try await ClientBootstrap(group: group)
            .connect(host: "127.0.0.1", port: server.localAddress!.port!).get()
        var buffer = client.allocator.buffer(capacity: 256)
        buffer.writeString("POST /upload HTTP/1.1\r\nHost: example.test\r\nContent-Length: 1000\r\n\r\n")
        buffer.writeString(String(repeating: "A", count: 100))
        try await client.writeAndFlush(buffer).get()
        try await client.close().get()

        let error = try #require(await forwarder.awaitFailure(), "the body stream should fail, not hang or finish")
        #expect(error is RequestBodyAborted, "got \(error)")
    }
}

/// Consumes the request-body stream the way the real forwarder does and records how
/// it ended, so the test can tell "failed" from "finished as if complete".
private final class BodyStreamRecorder: UpstreamForwarding, @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Error?
    private var finishedCleanly = false

    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        ForwardResult(statusCode: 200, headers: [], body: Data())
    }

    func forwardStream(
        method: String, url: URL, headers: [HeaderPair], body: RequestBody
    ) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await body.collect()
                    self.lock.lock(); self.finishedCleanly = true; self.lock.unlock()
                    continuation.yield(.head(statusCode: 200, httpVersion: nil, headers: []))
                    continuation.yield(.end)
                    continuation.finish()
                } catch {
                    self.lock.lock(); self.failure = error; self.lock.unlock()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Waits briefly for the stream to end. Returns the error it ended with, or nil
    /// if it finished cleanly or never ended at all — both of which are failures
    /// this suite wants to see reported rather than hung on.
    func awaitFailure() async -> Error? {
        for _ in 0..<100 {
            lock.lock()
            let (error, clean) = (failure, finishedCleanly)
            lock.unlock()
            if let error { return error }
            if clean { return nil }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }
}
