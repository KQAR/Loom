import Foundation
import Testing
import NIOCore
@testable import LoomProxyCore
import LoomSharedModels

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
        let snapshot = capture.snapshot()
        #expect(snapshot.body == Data("onetwothree".utf8))
        #expect(snapshot.fullBodyBytes == nil, "a complete capture reports no truncation")
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

    @Test func capture_capsAtLimit_andReportsTheWireSize() {
        let capture = RequestBodyCapture(cap: 10)
        capture.append(Data(repeating: 0x41, count: 8))
        capture.append(Data(repeating: 0x42, count: 8)) // only 2 of these fit
        let snapshot = capture.snapshot()
        #expect(snapshot.body.count == 10)
        // The upload was 16 bytes; the recorded copy is 10. Reporting 10 as the
        // whole body would misrepresent the capture.
        #expect(snapshot.fullBodyBytes == 16)
    }

    @Test func requestBody_collect() async throws {
        let bytes = try await RequestBody.bytes(Data("hi".utf8)).collect()
        #expect(bytes.body == Data("hi".utf8))
        #expect(bytes.trailers == nil)

        let bridge = RequestBodyBridge(capture: RequestBodyCapture())
        bridge.yield(Data("a".utf8)); bridge.yield(Data("b".utf8)); bridge.finish()
        let streamed = try await RequestBody.stream(bridge.chunks, contentLength: 2).collect()
        #expect(streamed.body == Data("ab".utf8))
    }

    /// A buffering decorator must stop at its cap rather than hold an unbounded body,
    /// and say which side and which holder — that text is what lands in `Flow.error`.
    @Test func requestBody_collect_failsPastTheBufferCap() async throws {
        let cap = BufferCap(bytes: 4, holder: .breakpoint)
        let bridge = RequestBodyBridge(capture: RequestBodyCapture())
        bridge.yield(Data("abc".utf8)); bridge.yield(Data("de".utf8)); bridge.finish()
        do {
            _ = try await RequestBody.stream(bridge.chunks, contentLength: nil).collect(cap: cap)
            Issue.record("expected the cap to throw")
        } catch let error as BufferedBodyTooLarge {
            #expect(error.side == .request)
            #expect(error.holder == .breakpoint)
        }

        // Exactly at the cap is fine; an in-memory body is never refused.
        let atCap = RequestBodyBridge(capture: RequestBodyCapture())
        atCap.yield(Data("abcd".utf8)); atCap.finish()
        #expect(try await RequestBody.stream(atCap.chunks, contentLength: 4).collect(cap: cap).body?.count == 4)
        #expect(try await RequestBody.bytes(Data(count: 10)).collect(cap: cap).body?.count == 10)
    }

    @Test func responseCollect_failsPastTheBufferCap() async throws {
        let events = AsyncThrowingStream<UpstreamResponseEvent, Error> { c in
            c.yield(.head(statusCode: 200, httpVersion: nil, headers: []))
            c.yield(.body(Data(count: 3))); c.yield(.body(Data(count: 3)))
            c.yield(.end(trailers: nil)); c.finish()
        }
        do {
            _ = try await events.collect(cap: BufferCap(bytes: 5, holder: .rule))
            Issue.record("expected the cap to throw")
        } catch let error as BufferedBodyTooLarge {
            #expect(error.side == .response)
            #expect(error.localizedDescription.contains("traffic rule"))
        }
    }

    /// Draining is what makes a streamed request's trailer section knowable, so the
    /// two have to come back together — a `collect()` that returned only bytes is
    /// how every buffering path used to eat them.
    @Test func requestBody_collect_carriesTheTrailerSectionOffAStream() async throws {
        let bridge = RequestBodyBridge(capture: RequestBodyCapture())
        bridge.yield(Data("payload".utf8))
        bridge.finish(trailers: [HeaderPair(name: "grpc-status", value: "5")])

        let collected = try await RequestBody
            .stream(bridge.chunks, contentLength: nil, trailers: bridge.trailers)
            .collect()
        #expect(collected.body == Data("payload".utf8))
        #expect(collected.trailers == [HeaderPair(name: "grpc-status", value: "5")])
    }

    /// Nil and empty are different answers: no trailer section at all, versus one
    /// that arrived carrying no fields.
    @Test func requestTrailers_distinguishAbsentFromEmpty() {
        #expect(RequestTrailers().current == nil)
        #expect(RequestTrailers([]).current == [])
    }
}
