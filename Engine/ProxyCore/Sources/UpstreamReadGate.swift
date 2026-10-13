import Foundation
import Synchronization
import NIOCore
import NIOHTTP1

/// Holds the upstream channel's reads while the response's consumer is behind.
///
/// The response leg had no back-pressure at all: `UpstreamResponseRelay` yielded every
/// chunk into an unbounded `AsyncThrowingStream` the moment it was read, and the socket
/// kept reading regardless of whether anyone was taking them. So the gap between how
/// fast the origin sends and how fast the client reads was held in Loom's memory —
/// measured in Release, a 1 GB download to a client reading at 200 MB/s peaked at
/// **1043 MB** RSS, i.e. the whole file.
///
/// This handler sits just before the relay and counts the (decompressed) body bytes
/// that have gone past it and not yet been *pulled* by the consumer
/// (`UpstreamResponseDemand.consumed`). Past `highWatermark` it swallows the channel's
/// `read()` — the same mechanism as NIO's `BackPressureHandler`, which also leaves
/// `autoRead` alone — and re-issues it once the consumer has brought the count back to
/// `lowWatermark`. On an h2 stream channel a held read is what stops the stream's
/// `WINDOW_UPDATE`s, so the origin is flow-controlled rather than merely buffered.
///
/// One gate per pipeline: the h1 connection's (kept across pooled exchanges) or an h2
/// stream's. `begin()` starts each exchange from zero, and a `consumed` call carries the
/// exchange it belongs to, so a consumer that abandoned bytes on a connection that then
/// went back to the pool cannot leave the next exchange stuck behind its count.
///
/// Escape-hatch kind 3 (ProxyCore/CLAUDE.md § Sendable escape hatches): everything
/// mutable is inside the `Mutex`, and the hatch exists only because `Channel` carries
/// no `Sendable` conformance. The release goes through `channel.read()` — thread-safe,
/// and it re-enters this handler from the tail, which is where the decision belongs —
/// so no `ChannelHandlerContext` is ever held. The channel is learned in
/// `handlerAdded` rather than at init because the h1 gate is built before its
/// connection exists, the cycle `UpstreamExchangeSlot` already lives with.
final class UpstreamReadGate: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias InboundOut = HTTPClientResponsePart
    typealias OutboundIn = HTTPClientRequestPart
    typealias OutboundOut = HTTPClientRequestPart

    /// Bytes read ahead of the consumer before reads stop. Large enough that a consumer
    /// keeping up never meets it (a few socket reads), small enough that the worst case
    /// is a rounding error next to the 5 MB capture copy.
    static let highWatermark = 1 << 20
    static let lowWatermark = 256 << 10

    private struct State {
        var outstanding = 0
        var heldRead = false
        var generation = 0
        var channel: Channel?
    }

    private let state = Mutex(State())

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        state.withLock { $0.channel = channel }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        state.withLock { $0.channel = nil }
    }

    /// Start an exchange: a clean count, and any read a previous exchange left held is
    /// released. Returns the generation `consumed` must quote.
    func begin() -> Int {
        let (generation, release) = state.withLock { state -> (Int, Channel?) in
            state.generation += 1
            state.outstanding = 0
            let release = state.heldRead ? state.channel : nil
            state.heldRead = false
            return (state.generation, release)
        }
        release?.read()
        return generation
    }

    /// The consumer took `bytes` off the stream. Any thread.
    func consumed(_ bytes: Int, generation: Int) {
        let release = state.withLock { state -> Channel? in
            guard state.generation == generation else { return nil }
            state.outstanding = max(0, state.outstanding - bytes)
            guard state.heldRead, state.outstanding <= Self.lowWatermark else { return nil }
            state.heldRead = false
            return state.channel
        }
        release?.read()
    }

    /// At or past the high watermark — whether `UpstreamInflationPacer` may feed the
    /// decompressor another slice.
    var isSaturated: Bool { state.withLock { $0.outstanding >= Self.highWatermark } }

    /// Decompressed bytes past this gate the consumer has not pulled.
    var outstandingBytes: Int { state.withLock { $0.outstanding } }

    /// Record a read someone below this gate swallowed on its behalf, so the next
    /// release re-issues it. Without this, a read the gate let through and the pacer
    /// then held would be lost, and the exchange would wait forever.
    func holdRead() {
        state.withLock { $0.heldRead = true }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case let .body(buffer) = unwrapInboundIn(data) {
            let bytes = buffer.readableBytes
            state.withLock { $0.outstanding += bytes }
        }
        context.fireChannelRead(data)
    }

    func read(context: ChannelHandlerContext) {
        let proceed = state.withLock { state -> Bool in
            guard state.outstanding >= Self.highWatermark else { return true }
            state.heldRead = true
            return false
        }
        if proceed { context.read() }
    }
}

/// Feeds a compressed response body to the decompressor a slice at a time, and only
/// while the consumer is keeping up.
///
/// `UpstreamReadGate` counts *decompressed* bytes, after the decompressor, and the
/// decompressor inflates each input buffer completely in one call: DEFLATE tops out
/// near 1032:1, so a single 64 KB socket read could become ~66 MB before the gate saw
/// any of it. Sliced to `sliceBytes` and fed only while the gate is below its
/// watermark, one step inflates at most ~4 MB, and the rest of the compressed input
/// waits here — compressed, which is the cheap form to wait in.
///
/// An uncompressed response passes straight through; there is nothing to pace.
///
/// Escape-hatch kind 1 (ProxyCore/CLAUDE.md § Sendable escape hatches): event-loop
/// confined, no lock.
final class UpstreamInflationPacer: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias InboundOut = HTTPClientResponsePart
    typealias OutboundIn = HTTPClientRequestPart
    typealias OutboundOut = HTTPClientRequestPart

    static let sliceBytes = 4 << 10

    private let gate: UpstreamReadGate
    private var compressed = false
    private var held = CircularBuffer<ByteBuffer>()
    /// The response's end, kept behind any held body so it cannot overtake it.
    private var heldEnd: HTTPHeaders??

    init(gate: UpstreamReadGate) {
        self.gate = gate
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            let encoding = head.headers[canonicalForm: "Content-Encoding"].first?.lowercased()
            compressed = encoding != nil && encoding != "identity"
            context.fireChannelRead(data)
        case let .body(buffer) where compressed:
            held.append(buffer)
            drain(context: context)
        case .body:
            context.fireChannelRead(data)
        case let .end(trailers):
            guard !held.isEmpty else {
                context.fireChannelRead(data)
                return
            }
            heldEnd = .some(trailers)
        }
    }

    func read(context: ChannelHandlerContext) {
        if !held.isEmpty {
            drain(context: context)
            // Still holding: the socket has nothing to add yet. The gate is saturated
            // (that is the only reason a drain stops early), so park the read with it.
            guard held.isEmpty else {
                gate.holdRead()
                return
            }
        }
        context.read()
    }

    private func drain(context: ChannelHandlerContext) {
        while !held.isEmpty, !gate.isSaturated {
            var first = held.removeFirst()
            let slice = first.readSlice(length: min(Self.sliceBytes, first.readableBytes))!
            if first.readableBytes > 0 { held.prepend(first) }
            context.fireChannelRead(wrapInboundOut(.body(slice)))
        }
        if held.isEmpty, let trailers = heldEnd {
            heldEnd = nil
            context.fireChannelRead(wrapInboundOut(.end(trailers)))
        }
    }
}

/// One exchange's link from the consumer back to whichever gate is serving it.
///
/// Created with the response stream, before Loom knows which connection — pooled,
/// fresh, h1 or an h2 stream — will carry the exchange, and bound to that gate when an
/// attempt arms. A retry rebinds; nothing the failed attempt yielded was a body, or it
/// would not have been retried.
final class UpstreamResponseDemand: Sendable {
    private let bound = Mutex<(gate: UpstreamReadGate, generation: Int)?>(nil)

    func bind(_ gate: UpstreamReadGate) {
        let generation = gate.begin()
        bound.withLock { $0 = (gate, generation) }
    }

    func consumed(_ bytes: Int) {
        guard bytes > 0, let current = bound.withLock({ $0 }) else { return }
        current.gate.consumed(bytes, generation: current.generation)
    }
}

/// An `AsyncIteratorProtocol` behind a reference, so a pull-based stream's `@Sendable`
/// producer closure can hold it. `@unchecked` because the iterator is not `Sendable`;
/// sound because `AsyncThrowingStream(unfolding:)` calls its producer once at a time,
/// from the single consumer.
final class PulledIterator<Base: AsyncIteratorProtocol>: @unchecked Sendable {
    private var base: Base
    init(_ base: Base) { self.base = base }
    func next() async throws -> Base.Element? { try await base.next() }
}

extension AsyncThrowingStream where Element == UpstreamResponseEvent, Failure == Error {
    /// The same events, pulled rather than pumped, reporting each body chunk to
    /// `demand` as the consumer takes it — the signal `UpstreamReadGate` paces on.
    ///
    /// Pull-based on purpose: a stream that copied `self` into a second buffer as fast
    /// as it could would move the unbounded queue rather than remove it. Cancelling
    /// the consumer cancels the pull, which terminates `self` and runs its cleanup
    /// exactly as before.
    func reportingConsumption(to demand: UpstreamResponseDemand) -> Self {
        let iterator = PulledIterator(makeAsyncIterator())
        return AsyncThrowingStream {
            let event = try await iterator.next()
            if case let .body(chunk)? = event { demand.consumed(chunk.count) }
            return event
        }
    }
}
