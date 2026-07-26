// Loom-free reproduction of the h2 upload stall — KQAR/Loom issue #99. See README.md.
//
// The EmbeddedChannel model (the h2-embedded target) passes every variant, so the
// missing ingredient is concurrency: in Loom the body consumer runs on a *different
// thread* and its demand-driven `read()` hops onto the event loop from off-loop. This
// rebuilds that shape with no Loom code and no TLS:
//
//   h2 client ──sockets──▶ h2 server, stream channel with autoRead off, chunks
//   bridged into a NIOThrowingAsyncSequenceProducer (high/low watermark 4/1) whose
//   produceMore() drives channel.read(), consumed by a Task on the cooperative pool.
//
// The upload is larger than one 65535-byte flow-control window, so it can only
// finish if consuming replenishes the window. A stall parks at exactly 65535.
import Foundation
import NIOCore
import NIOPosix
import NIOHPACK
import NIOHTTP2

setvbuf(stdout, nil, _IONBF, 0)

let payloadSize = 200_000
let chunkSize = 16_384
let iterations = Int(CommandLine.arguments.dropFirst().first.flatMap { Int($0) } ?? 200)
let perRunTimeout = TimeAmount.seconds(5)
/// H2MODE:
///   "lazy"     — Loom's shape: bridge + demand-driven read pump, autoRead flipped off
///                on the first DATA frame.
///   "autoread" — control: the same pump, but autoRead is never disabled.
///   "plain"    — control: no bridge, no pump, no autoRead change. Just count the
///                bytes and reply. THIS ONE STILL STALLS, which is what proves the
///                defect is not in Loom's usage.
let mode = ProcessInfo.processInfo.environment["H2MODE"] ?? "lazy"

// MARK: - The bridge under suspicion, rebuilt without Loom

final class Bridge: @unchecked Sendable {
    typealias Producer = NIOThrowingAsyncSequenceProducer<
        Int, Error, NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark, Delegate
    >

    let chunks: Producer
    private let source: Producer.Source
    private let delegate: Delegate

    init() {
        let delegate = Delegate()
        self.delegate = delegate
        let new = Producer.makeSequence(
            elementType: Int.self,
            backPressureStrategy: .init(lowWatermark: 1, highWatermark: 4),
            finishOnDeinit: false,
            delegate: delegate
        )
        self.source = new.source
        self.chunks = new.sequence
    }

    func attach(channel: Channel) { delegate.setChannel(channel) }

    func yield(_ byteCount: Int) {
        switch source.yield(byteCount) {
        case .produceMore: delegate.readMore()
        case .stopProducing, .dropped: break
        }
    }

    func finish() { source.finish() }

    final class Delegate: NIOAsyncSequenceProducerDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var channel: Channel?
        private var terminated = false

        func setChannel(_ channel: Channel) { lock.lock(); self.channel = channel; lock.unlock() }
        func produceMore() { readMore() }
        func didTerminate() { lock.lock(); terminated = true; channel = nil; lock.unlock() }
        func readMore() {
            lock.lock()
            let channel = terminated ? nil : self.channel
            lock.unlock()
            channel?.read()
        }
    }
}

/// Counts what each side achieved, so a stall reports the same numbers the Loom test does.
final class Counters: @unchecked Sendable {
    private let lock = NSLock()
    private var _consumed = 0
    private var _frames = 0
    var consumed: Int { lock.lock(); defer { lock.unlock() }; return _consumed }
    var frames: Int { lock.lock(); defer { lock.unlock() }; return _frames }
    private var _windowGrants = 0
    private var _lastOutboundWindow = -1
    var windowGrants: Int { lock.lock(); defer { lock.unlock() }; return _windowGrants }
    var lastOutboundWindow: Int { lock.lock(); defer { lock.unlock() }; return _lastOutboundWindow }
    func add(bytes: Int) { lock.lock(); _consumed += bytes; _frames += 1; lock.unlock() }
    func recordGrant(outboundWindow: Int) { lock.lock(); _windowGrants += 1; _lastOutboundWindow = outboundWindow; lock.unlock() }
    func reset() { lock.lock(); _consumed = 0; _frames = 0; _windowGrants = 0; _lastOutboundWindow = -1; lock.unlock() }
}

let counters = Counters()

/// Mirrors TLSInterceptHandler: bridge created lazily on the first DATA frame,
/// autoRead flipped off there, chunks yielded, consumer running as a Task.
final class ServerStreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload

    private var bridge: Bridge?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .headers:
            break
        case let .data(body):
            guard case let .byteBuffer(buffer) = body.data else { return }
            if mode == "plain" {
                counters.add(bytes: buffer.readableBytes)
                if body.endStream {
                    let headers = HPACKHeaders([(":status", "200")])
                    context.channel.writeAndFlush(
                        NIOAny(HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: true))),
                        promise: nil
                    )
                }
                return
            }
            if bridge == nil {
                let bridge = Bridge()
                bridge.attach(channel: context.channel)
                self.bridge = bridge
                if mode == "lazy" { _ = context.channel.setOption(ChannelOptions.autoRead, value: false) }
                let chunks = bridge.chunks
                let channel = context.channel
                Task {
                    // The consumer: another thread, pulling with back-pressure.
                    do {
                        for try await byteCount in chunks { counters.add(bytes: byteCount) }
                    } catch {}
                    // Respond once the body is drained, the way the forwarder does.
                    channel.eventLoop.execute {
                        let headers = HPACKHeaders([(":status", "200")])
                        channel.writeAndFlush(
                            NIOAny(HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: true))),
                            promise: nil
                        )
                    }
                }
            }
            bridge?.yield(buffer.readableBytes)
            if body.endStream { bridge?.finish(); bridge = nil }
        default:
            break
        }
    }

    // Without these, a run that stalls and gets its connection closed deinits the
    // producer's Source unfinished, which is a preconditionFailure in NIOCore.
    // (Loom's own handlers are missing exactly this — see the note in the report.)
    func channelInactive(context: ChannelHandlerContext) {
        bridge?.finish()
        bridge = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        bridge?.finish()
        bridge = nil
        context.fireErrorCaught(error)
    }
}

/// Counts the window grants the CLIENT receives. If the client is told it may send
/// more and still doesn't, the defect is on the sending side; if it is never told,
/// the server never emitted a WINDOW_UPDATE.
final class WindowUpdateSpy: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Never
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let update = event as? NIOHTTP2WindowUpdatedEvent, let outbound = update.outboundWindowSize {
            counters.recordGrant(outboundWindow: outbound)
        }
        context.fireUserInboundEventTriggered(event)
    }
}

/// Signals the client's main loop when the response lands.
final class ClientStreamHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTP2Frame.FramePayload
    private let done: EventLoopPromise<Void>
    init(done: EventLoopPromise<Void>) { self.done = done }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .headers = unwrapInboundIn(data) { done.succeed(()) }
    }
}

// MARK: - Run

let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)  // as Loom's engine runs
let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
defer {
    try? serverGroup.syncShutdownGracefully()
    try? clientGroup.syncShutdownGracefully()
}

let server = try ServerBootstrap(group: serverGroup)
    .serverChannelOption(ChannelOptions.backlog, value: 256)
    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    .childChannelInitializer { channel in
        channel.configureHTTP2Pipeline(mode: .server) { stream in
            stream.pipeline.addHandler(ServerStreamHandler())
        }.map { _ in () }
    }
    .bind(host: "127.0.0.1", port: 0).wait()
let port = server.localAddress!.port!
print("mode=\(mode)  server on :\(port), \(iterations) iterations of \(payloadSize) bytes\n")

var stalls = 0
for iteration in 1...iterations {
    counters.reset()
    let done = clientGroup.next().makePromise(of: Void.self)

    let channel = try ClientBootstrap(group: clientGroup)
        .connect(host: "127.0.0.1", port: port).wait()
    let multiplexer = try channel.configureHTTP2Pipeline(mode: .client).wait()
    try channel.pipeline.addHandler(WindowUpdateSpy()).wait()

    let streamReady = clientGroup.next().makePromise(of: Channel.self)
    multiplexer.createStreamChannel(promise: streamReady) { stream in
        stream.pipeline.addHandler(ClientStreamHandler(done: done))
    }
    let stream = try streamReady.futureResult.wait()

    stream.eventLoop.execute {
        let headers = HPACKHeaders([
            (":method", "POST"), (":scheme", "https"), (":path", "/upload"), (":authority", "example.test"),
        ])
        stream.write(NIOAny(HTTP2Frame.FramePayload.headers(.init(headers: headers))), promise: nil)
        var written = 0
        while written < payloadSize {
            let size = min(chunkSize, payloadSize - written)
            var buffer = ByteBufferAllocator().buffer(capacity: size)
            buffer.writeBytes([UInt8](repeating: 0x41, count: size))
            written += size
            stream.write(
                NIOAny(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(buffer), endStream: written == payloadSize))),
                promise: nil
            )
        }
        stream.flush()
    }

    let watchdog = stream.eventLoop.scheduleTask(in: perRunTimeout) {
        done.fail(ChannelError.connectTimeout(perRunTimeout))
    }

    do {
        try done.futureResult.wait()
        watchdog.cancel()
    } catch {
        stalls += 1
        let consumed = counters.consumed
        let marker = consumed == 65535 ? "  ← exactly one flow-control window" : ""
        print("STALL on iteration \(iteration): server consumed \(consumed) / \(payloadSize) bytes in \(counters.frames) frames\(marker); client received \(counters.windowGrants) window grants, last outbound window \(counters.lastOutboundWindow)")
    }
    try? channel.close().wait()

    if iteration % 25 == 0 { print("… \(iteration)/\(iterations) done, \(stalls) stalls") }
}

print("\n\(stalls) stalls in \(iterations) iterations")
try? server.close().wait()
exit(stalls == 0 ? 0 : 1)
