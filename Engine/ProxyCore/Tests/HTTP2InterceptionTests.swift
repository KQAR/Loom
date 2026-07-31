import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHTTP2
import NIOSSL
import NIOTLS
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// End-to-end: an HTTP/2 client (ALPN "h2") through the MITM proxy is decrypted,
/// demuxed, forwarded, and captured — proving the ALPN branch + h2→h1 stream path.
@Suite("HTTP/2 interception", .timeLimit(.minutes(1)))
struct HTTP2InterceptionTests {
    @Test func h2RequestIsDecryptedForwardedAndCaptured() async throws {
        let responseBody = #"{"via":"loom-h2"}"#
        let forwarder = StubForwarder(status: 200, body: Data(responseBody.utf8))
        let engine = ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())

        let port = try await engine.start(port: 0)
        await engine.setSSLScope(SSLScope(enabled: true, include: ["*"]))
        let caURL = try await engine.exportCACertificate()
        let caPEM = try String(contentsOf: caURL)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? group.syncShutdownGracefully()
            Task { await engine.stop() }
        }

        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(caPEM.utf8), format: .pem)])
        clientConfig.applicationProtocols = ["h2"]
        let clientCtx = try NIOSSLContext(configuration: clientConfig)

        let connected = group.next().makePromise(of: Void.self)
        let sender = ConnectSender(connected: connected)
        let client = try ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(sender) }
            .connect(host: "127.0.0.1", port: port).wait()
        defer { try? client.close().wait() }

        try connected.futureResult.wait()
        try client.pipeline.removeHandler(sender).wait()

        let tls = try NIOSSLClientHandler(context: clientCtx, serverHostname: "example.test")
        try client.pipeline.addHandler(tls, position: .first).wait()
        let multiplexer = try client.configureHTTP2Pipeline(mode: .client).wait()

        let responded = group.next().makePromise(of: H2Response.self)
        multiplexer.createStreamChannel(promise: nil) { stream in
            stream.pipeline.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)).flatMap {
                stream.pipeline.addHandler(H2RequestHandler(promise: responded))
            }
        }

        let response = try responded.futureResult.wait()
        #expect(response.status == 200)
        #expect(response.body == responseBody)

        let flows = try await engine.recentFlows(limit: 10)
        let flow = try #require(flows.first { $0.request.url.contains("example.test/h2/thing") })
        #expect(flow.request.method == "GET")
        #expect(flow.request.url.hasPrefix("https://"))
        #expect(flow.response?.statusCode == 200)
        #expect(forwarder.lastURL?.absoluteString == "https://example.test/h2/thing")
    }

    /// An h2 POST body (DATA frames, no Content-Length) must stream through and be
    /// captured. The payload is larger than the default 64 KiB flow-control window,
    /// so the client can only finish sending if the MITM side replenishes the window
    /// as our read()-driven bridge consumes it — proving h2 back-pressure works.
    ///
    /// Instrumented on purpose (issue #99): this test hangs its full time limit on CI
    /// roughly 1 % of the time. That stall is **not Loom's bug** — `Tools/h2-stall-repro/`
    /// reproduces it with SwiftNIO alone — so this instrumentation exists to tell that
    /// known flake apart from a real regression: a stall reads `upstream bytes
    /// consumed = 65535` (exactly one h2 flow-control window). Anything else is new.
    /// Every step is staged and
    /// counted and nothing is awaited with a blocking `wait()`. A stall now fails at
    /// `Self.uploadTimeout` with the stage it reached, how many bytes each side moved
    /// (client-flushed vs. upstream-consumed, sampled over the wait so a crawl is
    /// distinguishable from a dead stop) and a stack sample — instead of tripping the
    /// suite's time limit with no information.
    @Test func h2RequestBodyStreamsThroughAndIsCaptured() async throws {
        let progress = H2Progress()
        let forwarder = StreamingProgressForwarder(status: 200, body: Data("ok".utf8), progress: progress)
        let engine = ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())

        let port = try await engine.start(port: 0)
        await engine.setSSLScope(SSLScope(enabled: true, include: ["*"]))
        let caPEM = try String(contentsOf: try await engine.exportCACertificate())
        progress.mark("engine listening on :\(port)")

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? group.syncShutdownGracefully()
            Task { await engine.stop() }
        }

        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(caPEM.utf8), format: .pem)])
        clientConfig.applicationProtocols = ["h2"]
        let clientCtx = try NIOSSLContext(configuration: clientConfig)

        let connected = group.next().makePromise(of: Void.self)
        let sender = ConnectSender(connected: connected)
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(sender) }
            .connect(host: "127.0.0.1", port: port).get()
        defer { try? client.close().wait() }
        progress.mark("TCP connected")

        try await awaitOrReport(connected.futureResult, stage: "CONNECT ack",
                                timeout: Self.connectTimeout, progress: progress)
        progress.mark("CONNECT acked")
        try await client.pipeline.removeHandler(sender).get()

        let tls = try NIOSSLClientHandler(context: clientCtx, serverHostname: "example.test")
        try await client.pipeline.addHandler(tls, position: .first).get()
        try await client.pipeline.addHandler(HandshakeMarker(progress: progress), position: .after(tls)).get()
        let multiplexer = try await client.configureHTTP2Pipeline(mode: .client).get()
        progress.mark("h2 pipeline configured")

        var payload = Data(count: 200_000) // > one h2 flow-control window
        for i in payload.indices { payload[i] = UInt8(i & 0xFF) }

        let responded = group.next().makePromise(of: H2Response.self)
        let payloadCopy = payload
        multiplexer.createStreamChannel(promise: nil) { stream in
            stream.pipeline.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)).flatMap {
                stream.pipeline.addHandler(
                    H2UploadHandler(payload: payloadCopy, promise: responded, progress: progress)
                )
            }
        }

        let response = try await awaitOrReport(responded.futureResult, stage: "response end",
                                               timeout: Self.uploadTimeout, progress: progress)
        #expect(response.status == 200)

        #expect(forwarder.lastBody == payload, "the full h2 DATA body must reach upstream byte-for-byte")
        let flows = try await engine.recentFlows(limit: 10)
        let flow = try #require(flows.first { $0.request.url.contains("example.test/h2/upload") })
        #expect(flow.request.method == "POST")
        #expect(flow.request.body == payload, "the captured h2 request body should match (200KB < cap)")
    }

    /// Both comfortably inside the suite's 1-minute limit (with room for the stack
    /// sample), so the watchdog reports first. A passing run takes ~0.05 s.
    private static let connectTimeout: TimeInterval = 8
    private static let uploadTimeout: TimeInterval = 25
}

// MARK: - Stall diagnostics (issue #99)

/// Thread-safe record of how far the h2 upload exchange got: ordered stage marks,
/// monotonically growing byte counters, and periodic samples of those counters taken
/// while waiting. The point is to turn "it hung" into "it stalled after N bytes at
/// stage X, and stopped moving at t=+2 s".
private final class H2Progress: @unchecked Sendable {
    private let lock = NSLock()
    private let start = Date()
    private var stages: [(String, TimeInterval)] = []
    private var counters: [(name: String, value: Int)] = []
    private var samples: [String] = []
    /// The process-wide read counter is cumulative across the suite; baseline it so
    /// the report shows reads issued *for this exchange*.
    private let readsAtStart = RequestBodyBridge.readsIssued

    func mark(_ stage: String) {
        let at = Date().timeIntervalSince(start)
        lock.lock(); stages.append((stage, at)); lock.unlock()
    }

    func add(_ counter: String, _ amount: Int) {
        lock.lock(); defer { lock.unlock() }
        if let index = counters.firstIndex(where: { $0.name == counter }) {
            counters[index].value += amount
        } else {
            counters.append((counter, amount))
        }
    }

    /// Snapshot the counters into the report, so a stalled run shows whether bytes
    /// were still trickling or had stopped dead.
    ///
    /// `reads issued` is what makes the snapshot diagnostic rather than merely
    /// suggestive: a stall at exactly one 65535-byte window looks identical whether
    /// upstream failed to send a WINDOW_UPDATE (issue #99) or Loom's own read pump
    /// stopped asking. Reads still climbing while bytes sit still = we asked and got
    /// nothing (upstream). Reads frozen too = we stopped asking (ours).
    func sample() {
        lock.lock(); defer { lock.unlock() }
        let at = String(format: "%.1f", Date().timeIntervalSince(start))
        var values = counters.map { "\($0.name)=\($0.value)" }
        values.append("reads issued=\(RequestBodyBridge.readsIssued - readsAtStart)")
        samples.append("  t=+\(at)s \(values.joined(separator: " "))")
    }

    func report() -> String {
        lock.lock(); defer { lock.unlock() }
        var lines = ["stages reached:"]
        lines += stages.map { "  +\(String(format: "%.3f", $0.1))s  \($0.0)" }
        lines.append("counters:")
        lines += counters.isEmpty ? ["  (none)"] : counters.map { "  \($0.name) = \($0.value)" }
        // See `sample()`: this is what separates upstream's missing WINDOW_UPDATE
        // (issue #99) from a Loom-side read-pump regression. Both park at 65535.
        lines.append("  reads issued (this exchange) = \(RequestBodyBridge.readsIssued - readsAtStart)")
        if !samples.isEmpty {
            lines.append("samples while waiting:")
            lines += samples
        }
        return lines.joined(separator: "\n")
    }
}

private struct H2Stall: Error, CustomStringConvertible {
    let stage: String
    var description: String { "h2 upload stalled waiting for \(stage) — see the recorded issue for the stage timeline" }
}

/// Await `future` without blocking the test thread, giving up after `timeout` and
/// recording the progress report plus a stack sample. Deliberately not a task group:
/// `EventLoopFuture.get()` isn't cancellable, so a group would wait on the hung await
/// at scope exit and the watchdog could never report.
private func awaitOrReport<T>(
    _ future: EventLoopFuture<T>, stage: String, timeout: TimeInterval, progress: H2Progress
) async throws -> T {
    let box = ResumeOnce<T>()
    return try await withCheckedThrowingContinuation { continuation in
        box.arm(continuation)
        future.whenComplete { box.resume($0) }
        Task {
            let step: TimeInterval = 2
            var waited: TimeInterval = 0
            while waited < timeout {
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                waited += step
                if box.isResolved { return }
                progress.sample()
            }
            guard !box.isResolved else { return }
            let report = progress.report()
            let stack = processStackSample()
            // Also to stderr: the CI log keeps it even if the message gets clipped.
            FileHandle.standardError.write(Data("\n[loom h2 stall @ \(stage)]\n\(report)\n\(stack)\n".utf8))
            Issue.record(Comment(rawValue: "h2 upload stalled waiting for \(stage)\n\(report)\n\(stack)"))
            box.resume(.failure(H2Stall(stage: stage)))
        }
    }
}

/// Resolves a continuation exactly once, from whichever of the future or the watchdog
/// gets there first.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var resolved = false

    var isResolved: Bool { lock.lock(); defer { lock.unlock() }; return resolved }

    func arm(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock(); self.continuation = continuation; lock.unlock()
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        guard !resolved, let continuation else { lock.unlock(); return }
        resolved = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

/// A stack sample of this process, so a stall shows where each thread is parked (the
/// event loop inside NIOHTTP2 vs. the consumer `Task` awaiting a chunk). Best-effort:
/// if `sample` can't attach, say so rather than mask the stall.
private func processStackSample() -> String {
    let pid = ProcessInfo.processInfo.processIdentifier
    let path = NSTemporaryDirectory() + "loom-h2-stall-\(pid).txt"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    process.arguments = [String(pid), "1", "-file", path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return "stack sample:\n" + String(text.prefix(20_000))
    } catch {
        return "stack sample unavailable: \(error)"
    }
}

/// Separates "the TLS handshake never finished" from "h2 never got going".
private final class HandshakeMarker: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let progress: H2Progress

    init(progress: H2Progress) { self.progress = progress }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted(let negotiated) = event {
            progress.mark("client TLS handshake completed (alpn: \(negotiated ?? "none"))")
        }
        context.fireUserInboundEventTriggered(event)
    }
}

/// A stub upstream that consumes the request-body stream itself — like the real NIO
/// forwarder, and unlike `StubForwarder`'s buffered default — reporting how much of
/// the body actually reached it. Paired with the client's per-chunk flush counter,
/// this is what attributes a stall to the client, our read pump, or the consumer.
private final class StreamingProgressForwarder: UpstreamForwarding, @unchecked Sendable {
    let status: Int
    let body: Data
    private let progress: H2Progress
    private let lock = NSLock()
    private var _lastURL: URL?
    private var _lastBody: Data?
    var lastURL: URL? { lock.lock(); defer { lock.unlock() }; return _lastURL }
    var lastBody: Data? { lock.lock(); defer { lock.unlock() }; return _lastBody }

    init(status: Int, body: Data, progress: H2Progress) {
        self.status = status
        self.body = body
        self.progress = progress
    }

    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        lock.lock(); _lastURL = url; _lastBody = body; lock.unlock()
        return ForwardResult(
            statusCode: status,
            headers: [HeaderPair(name: "Content-Type", value: "application/json")],
            body: self.body
        )
    }

    func forwardStream(
        method: String, url: URL, headers: [HeaderPair], body: RequestBody
    ) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    self.progress.mark("upstream saw \(method) \(url.path)")
                    var collected = Data()
                    switch body {
                    case let .bytes(data):
                        collected = data ?? Data()
                        self.progress.mark("upstream got a buffered body (\(collected.count) bytes)")
                    case let .stream(chunks, _):
                        for try await chunk in chunks {
                            collected.append(chunk)
                            self.progress.add("upstream bytes consumed", chunk.count)
                            self.progress.add("upstream chunks consumed", 1)
                        }
                    }
                    self.progress.mark("upstream request body finished (\(collected.count) bytes)")
                    self.lock.lock(); self._lastURL = url; self._lastBody = collected; self.lock.unlock()
                    continuation.yield(.head(
                        statusCode: self.status, httpVersion: nil,
                        headers: [HeaderPair(name: "Content-Type", value: "application/json")]
                    ))
                    if !self.body.isEmpty { continuation.yield(.body(self.body)) }
                    continuation.yield(.end)
                    continuation.finish()
                    self.progress.mark("upstream response emitted")
                } catch {
                    self.progress.mark("upstream failed: \(error)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct H2Response { let status: Int; let body: String }

/// On an h2 stream: sends POST /h2/upload with a DATA body (no Content-Length),
/// collects the response status.
///
/// The body goes out in `chunkSize` writes, each with its own promise, so the write
/// promises measure how far h2's outbound flow control let the client get — which is
/// the signal that distinguishes "the MITM side never replenished the window" from a
/// stall further down (issue #99). A single flush at the end keeps the framing the
/// same as one big write: the codec splits on max-frame-size regardless.
private final class H2UploadHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let payload: Data
    private let chunkSize: Int
    private let promise: EventLoopPromise<H2Response>
    private let progress: H2Progress?
    private var status = 0

    init(payload: Data, promise: EventLoopPromise<H2Response>, progress: H2Progress? = nil, chunkSize: Int = 16_384) {
        self.payload = payload
        self.promise = promise
        self.progress = progress
        self.chunkSize = chunkSize
    }

    func channelActive(context: ChannelHandlerContext) {
        progress?.mark("client h2 stream active")
        var headers = HTTPHeaders()
        headers.add(name: "host", value: "example.test")
        let head = HTTPRequestHead(version: .init(major: 1, minor: 1), method: .POST, uri: "/h2/upload", headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var offset = payload.startIndex
        while offset < payload.endIndex {
            let end = payload.index(offset, offsetBy: min(chunkSize, payload.distance(from: offset, to: payload.endIndex)))
            let chunk = payload[offset..<end]
            var buffer = context.channel.allocator.buffer(capacity: chunk.count)
            buffer.writeBytes(chunk)
            let written = context.eventLoop.makePromise(of: Void.self)
            written.futureResult.whenSuccess { [progress] in progress?.add("client bytes flushed", chunk.count) }
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: written)
            offset = end
        }

        let done = context.eventLoop.makePromise(of: Void.self)
        done.futureResult.whenComplete { [progress] result in
            switch result {
            case .success: progress?.mark("client flushed the whole body + end")
            case let .failure(error): progress?.mark("client body write failed: \(error)")
            }
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: done)
        progress?.mark("client request head + body queued and flushed")
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            status = Int(head.status.code)
            progress?.mark("client got response head \(status)")
        case .body: break
        case .end:
            progress?.mark("client got response end")
            promise.succeed(H2Response(status: status, body: ""))
        }
    }
}

/// Sends the CONNECT and signals once the proxy's 200 ack arrives.
private final class ConnectSender: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let connected: EventLoopPromise<Void>
    private var acked = false

    init(connected: EventLoopPromise<Void>) { self.connected = connected }

    func channelActive(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: 64)
        buffer.writeString("CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\n\r\n")
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if !acked, let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes), text.contains("200") {
            acked = true
            connected.succeed(())
        }
    }
}

/// On an h2 stream (h1-shaped via the codec): sends GET /h2/thing, collects the response.
private final class H2RequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let promise: EventLoopPromise<H2Response>
    private var status = 0
    private var body = ""

    init(promise: EventLoopPromise<H2Response>) { self.promise = promise }

    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "host", value: "example.test")
        let head = HTTPRequestHead(version: .init(major: 1, minor: 1), method: .GET, uri: "/h2/thing", headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head): status = Int(head.status.code)
        case var .body(buffer): body += buffer.readString(length: buffer.readableBytes) ?? ""
        case .end: promise.succeed(H2Response(status: status, body: body))
        }
    }
}
