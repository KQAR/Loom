// Deterministic model of the h2 upload stall — KQAR/Loom issue #99. See README.md.
//
// This target does NOT reproduce, and that is the finding: a single-threaded,
// fully-synchronous model of every autoRead / read-timing combination passes, so the
// defect needs real concurrency (see the h2-sockets target).
//
// No Loom code: two EmbeddedChannels (h2 client + h2 server) wired byte-for-byte,
// the server's stream channel running with autoRead off and a demand-driven read
// pump — the sanctioned back-pressure pattern from NIOHTTP2's own tests. The client
// uploads more than one flow-control window, so it can only finish if the server
// keeps replenishing the inbound window as it consumes.
//
// The variants differ in *when* autoRead is disabled and *when* the next read() is
// issued, because the CI stall (server consumed exactly one 65535-byte window, then
// both sides slept forever) has to come from one of those two orderings.
import Foundation
import NIOCore
import NIOEmbedded
import NIOHPACK
import NIOHTTP2

setvbuf(stdout, nil, _IONBF, 0)

let payloadSize = 200_000
let chunkSize = 16_384

enum AutoReadFlip {
    case inInitializer  // upstream's own tests do this
    case onFirstDataFrame  // what Loom's TLSInterceptHandler does
}

enum ReadTiming {
    /// Inline in channelRead, the way `RequestBodyBridge.yield` does when the
    /// producer still has demand.
    case inline
    /// Queued on the event loop, the way `channel.read()` behaves when the consumer
    /// Task calls `produceMore()` from another thread — the read lands *after* the
    /// current delivery batch, not during it.
    case queuedOnEventLoop
    /// Not issued by the handler at all: the driver pulls one chunk per round,
    /// modelling a slow async consumer.
    case drivenExternally
}

final class PumpingRecorder: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload

    private let flip: AutoReadFlip
    private let timing: ReadTiming
    private(set) var bytesReceived = 0
    private(set) var dataFrames = 0
    private var flipped = false

    init(flip: AutoReadFlip, timing: ReadTiming) {
        self.flip = flip
        self.timing = timing
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case let .data(body) = payload, case let .byteBuffer(buffer) = body.data else { return }

        if flip == .onFirstDataFrame && !flipped {
            flipped = true
            _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
        }

        bytesReceived += buffer.readableBytes
        dataFrames += 1

        let channel = context.channel
        switch timing {
        case .inline: channel.read()
        case .queuedOnEventLoop: context.eventLoop.execute { channel.read() }
        case .drivenExternally: break
        }
    }
}

func interconnect(_ a: EmbeddedChannel, _ b: EmbeddedChannel) throws {
    var movedSomething = true
    var rounds = 0
    while movedSomething {
        rounds += 1
        if rounds > 10_000 { print("  (interconnect gave up after 10k rounds)"); return }
        movedSomething = false
        for (from, to) in [(a, b), (b, a)] {
            while let buffer = try from.readOutbound(as: ByteBuffer.self) {
                if buffer.readableBytes > 0 {
                    try to.writeInbound(buffer)
                    movedSomething = true
                }
            }
        }
        (a.eventLoop as! EmbeddedEventLoop).run()
        (b.eventLoop as! EmbeddedEventLoop).run()
    }
}

func runVariant(name: String, flip: AutoReadFlip, timing: ReadTiming) throws {
    let server = EmbeddedChannel()
    let client = EmbeddedChannel()

    var recorder: PumpingRecorder!
    let serverStream = server.eventLoop.makePromise(of: Channel.self)
    _ = try server.configureHTTP2Pipeline(mode: .server) { stream -> EventLoopFuture<Void> in
        let handler = PumpingRecorder(flip: flip, timing: timing)
        recorder = handler
        serverStream.succeed(stream)
        switch flip {
        case .onFirstDataFrame:
            return stream.pipeline.addHandler(handler)
        case .inInitializer:
            return stream.setOption(ChannelOptions.autoRead, value: false).flatMap {
                stream.pipeline.addHandler(handler)
            }
        }
    }.wait()
    let multiplexer = try client.configureHTTP2Pipeline(mode: .client).wait()

    try server.connect(to: SocketAddress(unixDomainSocketPath: "/nope")).wait()
    try client.connect(to: SocketAddress(unixDomainSocketPath: "/nope")).wait()
    try interconnect(client, server)

    let streamReady = client.eventLoop.makePromise(of: Channel.self)
    multiplexer.createStreamChannel(promise: streamReady) { $0.eventLoop.makeSucceededVoidFuture() }
    (client.eventLoop as! EmbeddedEventLoop).run()
    let stream = try streamReady.futureResult.wait()

    let headers = HPACKHeaders([(":method", "POST"), (":scheme", "https"), (":path", "/upload"), (":authority", "example.test")])
    stream.write(HTTP2Frame.FramePayload.headers(.init(headers: headers)), promise: nil)

    var written = 0
    while written < payloadSize {
        let size = min(chunkSize, payloadSize - written)
        var buffer = ByteBufferAllocator().buffer(capacity: size)
        buffer.writeBytes([UInt8](repeating: 0x41, count: size))
        written += size
        stream.write(HTTP2Frame.FramePayload.data(.init(data: .byteBuffer(buffer), endStream: written == payloadSize)), promise: nil)
    }
    stream.flush()

    // Pump first: the server can't have a stream channel (and the promise can't be
    // fulfilled) until the HEADERS bytes actually reach it. Waiting before this
    // deadlocks — an EmbeddedEventLoop only runs when we run it.
    try interconnect(client, server)

    // With autoRead off from the start nothing is ever delivered unless someone asks;
    // upstream's tests kick the first read the same way.
    if flip == .inInitializer {
        try serverStream.futureResult.wait().read()
        try interconnect(client, server)
    }

    // A slow async consumer: one chunk per round, until it stops making progress.
    if timing == .drivenExternally, let channel = try? serverStream.futureResult.wait() {
        var lastSeen = -1
        while recorder.bytesReceived != lastSeen && recorder.bytesReceived < payloadSize {
            lastSeen = recorder.bytesReceived
            channel.read()
            try interconnect(client, server)
        }
    }

    let received = recorder.bytesReceived
    let verdict = received == payloadSize ? "OK      " : "STALLED "
    let window = received == 65535 ? "  ← exactly one flow-control window" : ""
    print("\(verdict) \(name): \(received) / \(payloadSize) bytes, \(recorder.dataFrames) DATA frames\(window)")

    _ = try? server.finish()
    _ = try? client.finish()
}

print("payload \(payloadSize) bytes, initial flow-control window 65535\n")
try runVariant(name: "autoRead off in initializer  + inline read   (upstream pattern)", flip: .inInitializer, timing: .inline)
try runVariant(name: "autoRead off in initializer  + queued read", flip: .inInitializer, timing: .queuedOnEventLoop)
try runVariant(name: "autoRead off in initializer  + external read", flip: .inInitializer, timing: .drivenExternally)
try runVariant(name: "autoRead off on 1st DATA     + inline read   (Loom pattern)", flip: .onFirstDataFrame, timing: .inline)
try runVariant(name: "autoRead off on 1st DATA     + queued read", flip: .onFirstDataFrame, timing: .queuedOnEventLoop)
try runVariant(name: "autoRead off on 1st DATA     + external read", flip: .onFirstDataFrame, timing: .drivenExternally)
