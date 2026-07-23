import Foundation
import NIOCore
import NIOHTTP1

/// Request-body framing helpers shared by the plain and MITM request handlers.
enum RequestBodyStreaming {
    /// Whether the request head declares a body worth streaming (chunked, or a
    /// non-zero Content-Length). A GET/upgrade with neither is bodyless.
    static func hasBody(_ head: HTTPRequestHead) -> Bool {
        if head.headers.first(name: "transfer-encoding")?.lowercased().contains("chunked") == true { return true }
        if let length = contentLength(head) { return length > 0 }
        return false
    }

    /// The client's declared Content-Length, or nil (chunked / absent) so the
    /// forwarder re-frames as chunked upstream.
    static func contentLength(_ head: HTTPRequestHead) -> Int? {
        head.headers.first(name: "content-length").flatMap { Int($0) }
    }
}

/// The request body handed to the forwarder. Either fully materialized (replay, or
/// a body a rule/breakpoint forced us to buffer) or a live, back-pressured chunk
/// stream from the client that is consumed exactly once. Modeling it as a sum type
/// keeps the "stream when nothing needs the whole body, buffer when it does"
/// decision explicit at each decorator.
enum RequestBody: Sendable {
    case bytes(Data?)
    /// Live chunks + the client's declared Content-Length (nil when the client used
    /// chunked transfer-encoding, so the forwarder re-frames as chunked upstream).
    case stream(RequestChunks, contentLength: Int?)

    /// Drain to a single `Data` (the buffered fallback). Pulling respects the
    /// stream's back-pressure, so this never reads faster than the consumer here.
    func collect() async throws -> Data? {
        switch self {
        case let .bytes(data):
            return data
        case let .stream(chunks, _):
            var data = Data()
            for try await chunk in chunks { data.append(chunk) }
            return data
        }
    }
}

/// Type-eraser over the producer's async sequence so `RequestBody` doesn't carry
/// the producer's heavy generic signature everywhere.
struct RequestChunks: AsyncSequence, Sendable {
    typealias Element = Data
    let sequence: RequestBodyBridge.Producer

    func makeAsyncIterator() -> Iterator { Iterator(base: sequence.makeAsyncIterator()) }

    struct Iterator: AsyncIteratorProtocol {
        var base: RequestBodyBridge.Producer.AsyncIterator
        mutating func next() async throws -> Data? { try await base.next() }
    }
}

/// A bounded, thread-safe copy of a request body captured for the inspector.
/// Capped like the response side (`StreamRelay.captureCap`) so an enormous upload
/// streams to upstream in full while the recorded copy can't grow the store without
/// limit. Filled as chunks are ingested, independent of whether the forwarder
/// streams the body through or buffers it.
final class RequestBodyCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let cap: Int

    init(cap: Int = StreamRelay.captureCap) { self.cap = cap }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard data.count < cap else { return }
        let remaining = cap - data.count
        data.append(chunk.count <= remaining ? chunk : chunk.prefix(remaining))
    }

    /// The bytes captured so far (a value copy). Complete once the request stream
    /// has finished — which, by HTTP ordering, is before the response head arrives.
    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

/// Bridges a client channel's inbound request-body chunks into a back-pressured
/// async sequence the forwarder consumes. Reads are demand-driven: the producer's
/// high/low-watermark strategy calls `produceMore()` when the consumer drains,
/// which issues the next `channel.read()`, so a fast uploader can't outrun a slow
/// upstream — in-flight bytes stay bounded to the watermark, not the body size.
///
/// The client channel runs with `autoRead` off during a body stream (the handler
/// toggles it), so the only reads are the ones this bridge asks for.
final class RequestBodyBridge: @unchecked Sendable {
    typealias Producer = NIOThrowingAsyncSequenceProducer<
        Data,
        Error,
        NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark,
        Delegate
    >

    /// Element-count watermark: chunks are one NIO read each (~a recv buffer, tens
    /// of KB), so a few in flight keeps memory bounded without starving throughput.
    private static let lowWatermark = 1
    private static let highWatermark = 4

    let capture: RequestBodyCapture
    private let source: Producer.Source
    private let delegate: Delegate

    /// The sequence the forwarder consumes. Held by `RequestBody.stream`, never by
    /// this bridge, so the producer's deinit-teardown contract isn't violated.
    let chunks: RequestChunks

    init(capture: RequestBodyCapture) {
        self.capture = capture
        let delegate = Delegate()
        self.delegate = delegate
        let new = Producer.makeSequence(
            elementType: Data.self,
            backPressureStrategy: .init(lowWatermark: Self.lowWatermark, highWatermark: Self.highWatermark),
            finishOnDeinit: false,
            delegate: delegate
        )
        self.source = new.source
        self.chunks = RequestChunks(sequence: new.sequence)
    }

    /// Wire the client channel so the bridge can pull the next read on demand.
    func attach(channel: Channel) { delegate.setChannel(channel) }

    /// Feed one inbound body chunk. Captures a capped copy, yields to the consumer,
    /// and — when the consumer still wants more — pulls the next read immediately.
    func yield(_ chunk: Data) {
        capture.append(chunk)
        switch source.yield(chunk) {
        case .produceMore: delegate.readMore()
        case .stopProducing, .dropped: break // wait for the delegate's produceMore()
        }
    }

    func finish() { source.finish() }
    func fail(_ error: Error) { source.finish(error) }

    /// Drives `channel.read()` from producer demand. `Channel.read()` is safe to
    /// call from any thread (it hops to the event loop internally).
    final class Delegate: NIOAsyncSequenceProducerDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var channel: Channel?
        private var terminated = false

        func setChannel(_ channel: Channel) {
            lock.lock(); defer { lock.unlock() }
            self.channel = channel
        }

        func produceMore() { readMore() }

        func didTerminate() {
            lock.lock(); terminated = true; channel = nil; lock.unlock()
        }

        func readMore() {
            lock.lock()
            let channel = terminated ? nil : self.channel
            lock.unlock()
            channel?.read()
        }
    }
}
