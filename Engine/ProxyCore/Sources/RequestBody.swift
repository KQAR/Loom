import Foundation
import Synchronization
import LoomSharedModels
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1

/// Request-body framing helpers shared by the plain and MITM request handlers.
enum RequestBodyStreaming {
    /// The client's declared Content-Length, or nil (chunked / h2 DATA / absent) so
    /// the forwarder re-frames as chunked upstream.
    static func contentLength(_ head: HTTPRequestHead) -> Int? {
        head.headers.first(name: "content-length").flatMap { Int($0) }
    }
}

/// A request's trailer field section, which for a live stream is **not known until
/// the body has finished** — the client sends it after the last chunk (chunked
/// `.end` trailers, or an h2 HEADERS frame following the DATA).
///
/// So it is a box rather than a value on the body: the forwarder writes the request
/// in one pass and only reaches the trailers after draining, and nothing else in the
/// path has a place to put a fact that arrives that late. For a buffered body the
/// value is simply known up front.
///
/// **Read it only after the chunk sequence has ended.** The bridge fills it before
/// `finish()`, so a consumer that has seen the sequence terminate is guaranteed to
/// see whatever arrived; a read before that answers nil, which is the honest answer
/// at that point rather than a wrong one.
final class RequestTrailers: Sendable {
    private let value = Mutex<[HeaderPair]?>(nil)

    init(_ initial: [HeaderPair]? = nil) {
        value.withLock { $0 = initial }
    }

    /// Nil means no trailer section arrived; `[]` means one did and it was empty.
    var current: [HeaderPair]? { value.withLock { $0 } }

    func set(_ trailers: [HeaderPair]?) {
        value.withLock { $0 = trailers }
    }
}

/// What `RequestBody.collect()` produces: the whole body **and** whatever trailer
/// section followed it. The two are returned together because draining is the act
/// that makes the second one knowable — a caller that took only the bytes would
/// silently drop the trailers, which is exactly what every buffering decorator did
/// before this existed.
struct CollectedRequestBody: Sendable {
    var body: Data?
    var trailers: [HeaderPair]?
}

/// The request body handed to the forwarder. Either fully materialized (replay, or
/// a body a rule/breakpoint forced us to buffer) or a live, back-pressured chunk
/// stream from the client that is consumed exactly once. Modeling `source` as a sum
/// type keeps the "stream when nothing needs the whole body, buffer when it does"
/// decision explicit at each decorator.
///
/// `.bytes(_)` / `.stream(_, contentLength:)` remain the spelling at every
/// construction site — they are factories now rather than cases, so that adding the
/// trailer channel did not touch a hundred call sites that have no trailers to give.
struct RequestBody: Sendable {
    enum Source: Sendable {
        case bytes(Data?)
        /// Live chunks + the client's declared Content-Length (nil when the client used
        /// chunked transfer-encoding, so the forwarder re-frames as chunked upstream).
        case stream(RequestChunks, contentLength: Int?)
    }

    var source: Source
    /// The trailer section, when there is a channel for one at all. Nil for a body
    /// that cannot have trailers (a synthesized replay, a mock) — which is a
    /// different statement from a box holding nil, i.e. "there was a client and it
    /// sent none".
    var trailers: RequestTrailers?

    static func bytes(_ data: Data?, trailers: [HeaderPair]? = nil) -> RequestBody {
        RequestBody(source: .bytes(data), trailers: trailers.map(RequestTrailers.init))
    }

    static func stream(
        _ chunks: RequestChunks, contentLength: Int?, trailers: RequestTrailers? = nil
    ) -> RequestBody {
        RequestBody(source: .stream(chunks, contentLength: contentLength), trailers: trailers)
    }

    /// Drain to a single `Data` plus the trailer section (the buffered fallback).
    /// Pulling respects the stream's back-pressure, so this never reads faster than
    /// the consumer here. The trailers are read *after* the sequence ends, which is
    /// the only point at which they exist.
    ///
    /// `cap` bounds a *live* body only: a `.bytes` body is already in memory, so
    /// refusing it would free nothing.
    func collect(cap: BufferCap? = nil) async throws -> CollectedRequestBody {
        switch source {
        case let .bytes(data):
            return CollectedRequestBody(body: data, trailers: trailers?.current)
        case let .stream(chunks, _):
            var data = Data()
            for try await chunk in chunks {
                try cap?.check(holding: data.count, adding: chunk.count, side: .request)
                data.append(chunk)
            }
            return CollectedRequestBody(body: data, trailers: trailers?.current)
        }
    }

    /// Consume the body without keeping it, returning the trailer section — for an
    /// exchange whose own body goes nowhere (a block, a mock, a body a rule replaces).
    /// Draining rather than ignoring it is what lets the client finish its upload and
    /// the capture copy (`RequestBodyCapture`) record it; holding none of it is what
    /// lets an upload of any size get its answer.
    func drain() async throws -> [HeaderPair]? {
        if case let .stream(chunks, _) = source {
            for try await _ in chunks {}
        }
        return trailers?.current
    }
}

/// How much a buffering decorator may hold of one body before it gives up.
///
/// A matched breakpoint, or a rule that edits a body, rewrites the response or
/// short-circuits, has to hold the *whole* body — and before this nothing bounded
/// that: one `set_rule` matching a large download or an endless SSE stream would
/// accumulate it in memory up to the decompressor's 1 GB limit, per exchange.
/// Over the cap the exchange **fails** with `BufferedBodyTooLarge` rather than
/// passing through unedited: forwarding the original would silently skip a rule or a
/// hold the operator armed, and the failure lands in `Flow.error` where an agent reads
/// it.
///
/// Only a rule that needs the *original* body buffers it — one with a body
/// substitution. A block/mock/mapLocal, or a body replaced wholesale, drains the client's
/// body without keeping it (`RequestBody.drain`), and a response edit leaves the request
/// streaming; see `RuleApplyingForwarder.plan`.
struct BufferCap: Sendable {
    static let maxBytes = 64 << 20

    let bytes: Int
    let holder: BufferedBodyTooLarge.Holder

    static let rule = BufferCap(bytes: maxBytes, holder: .rule)
    static let breakpoint = BufferCap(bytes: maxBytes, holder: .breakpoint)

    /// Subtraction, never `held + chunk`: the chunk length is the peer's.
    func check(holding held: Int, adding chunk: Int, side: BufferedBodyTooLarge.Side) throws {
        guard chunk > bytes - held else { return }
        Log.rules.error("A \(holder.rawValue, privacy: .public) buffered a \(side.rawValue, privacy: .public) body past \(bytes) bytes; failing the exchange.")
        throw BufferedBodyTooLarge(side: side, limit: bytes, holder: holder)
    }
}

struct BufferedBodyTooLarge: Error, LocalizedError {
    enum Side: String, Sendable { case request, response }
    enum Holder: String, Sendable { case rule = "traffic rule", breakpoint }

    let side: Side
    let limit: Int
    let holder: Holder

    var errorDescription: String? {
        let why = switch holder {
        case .rule: "A matched traffic rule needs the whole \(side.rawValue) body in memory (it edits a body, rewrites the response, or answers in Loom's place)"
        case .breakpoint: "A matched breakpoint holds the whole exchange in memory so it can be edited"
        }
        return "\(why), and the \(side.rawValue) body passed Loom's \(limit >> 20) MB buffering limit, so the exchange was failed rather than buffered further. Narrow the \(holder.rawValue)'s match so it does not cover large or endless transfers."
    }
}

/// The client went away — connection closed or errored — before its request body
/// was complete. The stream is *failed* rather than finished so the forwarder can't
/// mistake a truncated upload for a whole one, and so the exchange records an error
/// instead of a plausible-looking short request.
struct RequestBodyAborted: Error, CustomStringConvertible {
    let reason: String
    var description: String { "the client aborted the request body: \(reason)" }
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
final class RequestBodyCapture: Sendable {
    private struct State {
        var data = Data()
        /// Every byte seen, including those past the cap — so a truncated capture can
        /// report the real upload size instead of pretending the body ended at 5 MB.
        var wireBytes = 0
    }

    private let state = Mutex(State())
    private let cap: Int

    init(cap: Int = StreamRelay.captureCap) { self.cap = cap }

    func append(_ chunk: Data) {
        state.withLock { state in
            state.wireBytes += chunk.count
            guard state.data.count < cap else { return }
            let remaining = cap - state.data.count
            state.data.append(chunk.count <= remaining ? chunk : chunk.prefix(remaining))
        }
    }

    /// The bytes captured so far (a value copy) plus, when the cap truncated them,
    /// the total that actually flowed. Complete once the request stream has
    /// finished — which, by HTTP ordering, is before the response head arrives.
    func snapshot() -> (body: Data, fullBodyBytes: Int?) {
        state.withLock { ($0.data, $0.wireBytes > $0.data.count ? $0.wireBytes : nil) }
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
    /// Filled from the client's `.end` before the sequence is finished, so a
    /// consumer that has drained the chunks can read it and be sure. Handed to the
    /// forwarder inside `RequestBody.stream`.
    let trailers = RequestTrailers()
    private let source: Producer.Source
    /// Internal rather than private so `RequestBodyReadPumpTests` can drive its
    /// lifecycle (`didTerminate`) without a live consumer.
    let delegate: Delegate

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

    /// End the body stream, recording the client's trailer section first so a
    /// consumer that wakes on the termination already sees it. Order matters and is
    /// the whole contract of `RequestTrailers`.
    func finish(trailers: [HeaderPair]? = nil) {
        if let trailers { self.trailers.set(trailers) }
        source.finish()
    }
    func fail(_ error: Error) { source.finish(error) }

    /// Terminate a body stream whose client vanished mid-upload. **Not optional
    /// housekeeping**: the producer's `Source` is built with `finishOnDeinit: false`,
    /// so deiniting one that was never finished is a `preconditionFailure` inside
    /// NIOCore — an aborted upload would take the whole process down. Every handler
    /// that owns a bridge must call this from `channelInactive` and `errorCaught`.
    func abort(reason: String) { fail(RequestBodyAborted(reason: reason)) }

    /// Total `channel.read()` calls this process has issued from body-stream demand.
    ///
    /// A diagnostic seam, not state anything depends on (sibling of
    /// `BreakpointStore.timeoutResolutions`). It exists because the h2 upload stall
    /// (issue #99) and a Loom-side back-pressure regression are *indistinguishable*
    /// from the byte counters alone: both park with exactly one 65535-byte window
    /// consumed. Reads-issued separates them — "we asked for more and got nothing"
    /// is upstream's bug; "we never asked" is ours. Without it the documented
    /// discriminator ("a stall reads consumed = 65535") can't actually tell the two
    /// apart, so a real regression would be waved through as the known flake.
    static var readsIssued: Int { readCounter.withLockedValue { $0 } }
    private static let readCounter = NIOLockedValueBox(0)

    /// Drives `channel.read()` from producer demand. `Channel.read()` is safe to
    /// call from any thread (it hops to the event loop internally).
    final class Delegate: NIOAsyncSequenceProducerDelegate, Sendable {
        /// `Channel` has no `Sendable` conformance, which is exactly the case a
        /// `Mutex` is for: the reference is only ever reachable under the lock, so the
        /// class needs no `@unchecked`.
        private struct State {
            var channel: Channel?
            var terminated = false
        }

        private let state = Mutex(State())

        func setChannel(_ channel: Channel) {
            state.withLock { $0.channel = channel }
        }

        func produceMore() { readMore() }

        func didTerminate() {
            state.withLock { $0.terminated = true; $0.channel = nil }
        }

        func readMore() {
            let channel = state.withLock { $0.terminated ? nil : $0.channel }
            guard let channel else { return }
            RequestBodyBridge.readCounter.withLockedValue { $0 += 1 }
            channel.read()
        }
    }
}
