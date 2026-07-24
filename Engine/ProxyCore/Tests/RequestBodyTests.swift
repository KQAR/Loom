import Foundation
import Testing
import NIOCore
@testable import ProxyCore

/// Contract for the request-body bridge + `RequestBody`: chunks yielded into the
/// bridge come out of the consumed stream in order, a capped copy is captured, and
/// `collect()` materializes the buffered fallback.
@Suite struct RequestBodyTests {
    @Test func bridge_streamsChunksInOrderAndCaptures() async throws {
        let capture = RequestBodyCapture()
        let bridge = RequestBodyBridge(capture: capture)
        // Produce first (bounded internal buffering), then consume.
        for part in ["one", "two", "three"] { bridge.yield(Data(part.utf8)) }
        bridge.finish()

        var received: [String] = []
        for try await chunk in bridge.chunks { received.append(String(decoding: chunk, as: UTF8.self)) }

        #expect(received == ["one", "two", "three"])
        #expect(capture.snapshot() == Data("onetwothree".utf8))
    }

    @Test func bridge_failPropagatesError() async {
        struct Boom: Error {}
        let bridge = RequestBodyBridge(capture: RequestBodyCapture())
        bridge.yield(Data("partial".utf8))
        bridge.fail(Boom())

        do {
            for try await _ in bridge.chunks {}
            Issue.record("expected the stream to throw")
        } catch is Boom {
            // expected
        } catch { Issue.record("unexpected error: \(error)") }
    }

    @Test func capture_capsAtLimit() {
        let capture = RequestBodyCapture(cap: 10)
        capture.append(Data(repeating: 0x41, count: 8))
        capture.append(Data(repeating: 0x42, count: 8)) // only 2 of these fit
        #expect(capture.snapshot().count == 10)
    }

    @Test func requestBody_collect() async throws {
        let bytes = try await RequestBody.bytes(Data("hi".utf8)).collect()
        #expect(bytes == Data("hi".utf8))

        let bridge = RequestBodyBridge(capture: RequestBodyCapture())
        bridge.yield(Data("a".utf8)); bridge.yield(Data("b".utf8)); bridge.finish()
        let streamed = try await RequestBody.stream(bridge.chunks, contentLength: 2).collect()
        #expect(streamed == Data("ab".utf8))
    }
}
