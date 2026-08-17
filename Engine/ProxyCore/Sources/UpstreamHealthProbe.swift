import Foundation
import Synchronization
import NIOCore
import NIOHTTP2

/// A pooled connection that stopped answering at the protocol level.
///
/// Raised **only** on positive evidence — an h2 PING that went unanswered inside its
/// deadline — never on a slow origin. That distinction is what lets
/// `NIOStreamingForwarder.isTransportTeardown` accept it: "the transport underneath
/// is gone" is the same claim an RST makes, so a non-idempotent request may be
/// re-sent on a fresh connection for the same reason a reaped keep-alive lets it.
/// A first-byte wait that expires is *not* this error until the PING has failed too.
enum UpstreamLivenessError: Error, CustomStringConvertible {
    /// `idleMS` is how long the connection sat unused before it was handed out;
    /// `waitedMS` how long the probe waited for the ACK. Both are in the message
    /// because "which of the two clocks caught this" is the first thing anyone asks.
    case connectionUnresponsive(host: String, port: Int, idleMS: Int, waitedMS: Int)

    var description: String {
        switch self {
        case let .connectionUnresponsive(host, port, idleMS, waitedMS):
            return """
                the pooled HTTP/2 connection to \(host):\(port) did not answer a PING within \
                \(waitedMS) ms after \(idleMS) ms idle — treating it as gone
                """
        }
    }
}

/// Connection-level liveness for an upstream HTTP/2 socket.
///
/// **Why a PING and not a read timeout.** A socket whose peer has vanished without a
/// FIN stays `isActive` forever: a write into it succeeds (it lands in this host's
/// send buffer) and the failure surfaces only when TCP gives up retransmitting —
/// measured on real traffic at **33–51 seconds**, during which the exchange looks to
/// every surface like a slow origin. RFC 9113 §6.7's PING is the protocol's own
/// answer to "is this connection still there", and its ACK is mandatory and
/// unconditional: an origin that is merely busy still answers it, so a missing ACK
/// separates a dead connection from a slow one, which no timer on the response can.
///
/// Sits at the **tail** of the connection channel, after the multiplexer, because
/// that is where root-stream frames arrive: `HTTP2CommonInboundStreamMultiplexer`
/// forwards every `streamID == .rootStream` frame down the pipeline, and PING is one.
// @unchecked Sendable: `context` is event-loop confined (escape-hatch kind 1 — see
// ProxyCore/CLAUDE.md § Sendable escape hatches) and everything a caller on another
// thread touches lives inside the `Mutex`. `ping` never reads `context` directly; it
// hops with `eventLoop.execute`, which is the sanctioned way back onto the loop.
final class UpstreamHealthProbe: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame
    typealias InboundOut = HTTP2Frame

    private struct State {
        /// Monotonically increasing, so two probes in flight cannot be confused for
        /// each other — an origin is free to answer them out of order.
        var nextToken: UInt64 = 1
        var pending: [UInt64: EventLoopPromise<Void>] = [:]
    }

    private let state = Mutex(State())
    /// Event-loop confined; only ever touched on the loop.
    private var context: ChannelHandlerContext?

    // MARK: - Probing, callable from any thread

    /// Send a PING and resolve when its ACK comes back, or fail at `timeout`.
    ///
    /// The returned future is failed — never left hanging — for every way this can go
    /// wrong: no pipeline, a write that fails, the channel going away, the deadline.
    /// A hanging liveness check would be the thing it exists to prevent.
    /// - Parameter eventLoop: the connection channel's own loop. Passed in rather than
    ///   read off a stored context, so this is callable before `handlerAdded` has run
    ///   and needs no fallback loop of its own.
    func ping(
        on eventLoop: EventLoop, timeout: TimeAmount,
        failure: @autoclosure @escaping @Sendable () -> Error
    ) -> EventLoopFuture<Void> {
        let promise = eventLoop.makePromise(of: Void.self)
        let token = state.withLock { state -> UInt64 in
            let token = state.nextToken
            state.nextToken &+= 1
            state.pending[token] = promise
            return token
        }
        // Back onto the loop before touching `context`, capturing nothing but `self`
        // and two value types — the rule an event-loop-confined handler lives by.
        eventLoop.execute { [self] in
            guard let context else {
                resolve(token: token, with: .failure(ForwarderError.connectionClosed))
                return
            }
            let frame = HTTP2Frame(
                streamID: .rootStream, payload: .ping(HTTP2PingData(withInteger: token), ack: false)
            )
            context.writeAndFlush(NIOAny(frame)).assumeIsolated().whenFailure { [self] error in
                resolve(token: token, with: .failure(error))
            }
        }
        // Deliberately not cancelled when the ACK wins: a timer firing against a
        // token that is no longer pending is a no-op, and keeping a `Scheduled`
        // handle alive across threads to save one no-op is the worse trade.
        eventLoop.scheduleTask(in: timeout) { [self] in
            resolve(token: token, with: .failure(failure()))
        }
        return promise.futureResult
    }

    // MARK: - ChannelInboundHandler

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        failAll(ForwarderError.connectionClosed)
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(ForwarderError.connectionClosed)
        context.fireChannelInactive()
    }

    /// A PING **ACK** resolves its probe and is still forwarded: this handler
    /// observes, it does not consume. Anything else passes straight through.
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        if case let .ping(pingData, ack) = frame.payload, ack {
            resolve(token: pingData.integer, with: .success(()))
        }
        context.fireChannelRead(data)
    }

    // MARK: - Pending bookkeeping

    private func resolve(token: UInt64, with result: Result<Void, Error>) {
        // Take the promise out under the lock and complete it outside: completing one
        // runs a waiter's continuation, which must never happen inside the critical
        // section (ProxyCore/CLAUDE.md § Sendable escape hatches).
        let promise = state.withLock { $0.pending.removeValue(forKey: token) }
        guard let promise else { return }
        promise.completeWith(result)
    }

    private func failAll(_ error: Error) {
        let pending = state.withLock { state -> [EventLoopPromise<Void>] in
            let waiting = Array(state.pending.values)
            state.pending = [:]
            return waiting
        }
        for promise in pending { promise.fail(error) }
    }
}
