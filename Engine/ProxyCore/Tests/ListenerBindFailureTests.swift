import Foundation
import LoomSharedModels
import NIOCore
import NIOPosix
import Testing

@testable import LoomProxyCore

/// What happens when a port Loom wants is already someone else's.
///
/// The measured case behind both of these: Whistle listening on `*:9090` (IPv6
/// wildcard). Loom's `127.0.0.1:9090` bind succeeded — the two do not collide — so
/// the proxy came up healthy, and only the rebind to `0.0.0.0` that phone onboarding
/// needs hit `EADDRINUSE`. What the operator saw was "The operation couldn't be
/// completed. (NIOCore.IOError error 1.)", and what they were left with was an engine
/// reporting a running proxy on a port with no socket on it.
@Suite("Listener bind failures", .timeLimit(.minutes(1)))
struct ListenerBindFailureTests {
    private func makeEngine() -> ProxyEngine {
        ProxyEngine(forwarder: BindStubUpstream(), caStore: InMemoryCAStore())
    }

    /// Holds a real listening socket, so the failure under test is the kernel's
    /// actual refusal rather than a stub's idea of one. On the singleton group,
    /// which needs no shutdown — `syncShutdownGracefully` is `noasync`, and a
    /// `defer` in an async test cannot await.
    private func occupy(host: String, port: Int = 0) async throws -> Channel {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port)
            .get()
    }

    /// The error names the address and the reason. `IOError` is not a
    /// `LocalizedError`, so without this the popover and the port editor both show
    /// Foundation's placeholder — which names neither.
    @Test func startOnATakenPort_saysWhichPortAndWhy() async throws {
        let held = try await occupy(host: "127.0.0.1")
        let taken = held.localAddress?.port ?? 0

        let engine = makeEngine()
        do {
            _ = try await engine.start(port: taken)
            Issue.record("bound a port that is already held")
        } catch let error as ProxyControlError {
            let message = error.message
            #expect(message.contains("\(taken)"), "names the port: \(message)")
            #expect(message.contains("already in use"), "names the reason: \(message)")
            #expect(!message.contains("IOError"), "no raw NIO error: \(message)")
        }
        #expect(await engine.isRunning == false)
        await engine.stopForTest()
        try await held.close()
    }

    /// A failed move puts the listener back. Throwing without this leaves the engine
    /// `running` with nothing listening — every surface reporting a healthy proxy on
    /// a port where no socket exists, and the capture silently over.
    ///
    /// Skipped without a LAN IPv4, because that is what makes `0.0.0.0` a *different*
    /// bind from the loopback one this starts on.
    @Test(.enabled(if: LANAddress.primaryIPv4() != nil, "needs a LAN IPv4 address"))
    func failedRebind_returnsTheListenerToLoopback() async throws {
        let engine = makeEngine()
        let port = try await engine.start(port: 0)
        #expect(port > 0)

        // Take the wildcard on the port Loom is holding on loopback. Loom's own
        // listener is unaffected — this is exactly the collision Whistle caused.
        let held = try await occupy(host: "0.0.0.0", port: port)

        await #expect(throws: ProxyControlError.self) {
            _ = try await engine.startPhoneOnboarding(provisioningPort: 0)
        }

        // Still running, still on loopback, still on the same port — and still
        // actually accepting, which is the half a status flag cannot promise.
        #expect(await engine.isRunning)
        #expect(await engine.status().listenHost == "127.0.0.1")
        #expect(await engine.status().port == port)
        let connection = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(host: "127.0.0.1", port: port)
            .get()
        try await connection.close()

        await engine.stopForTest()
        try await held.close()
    }
}

private struct BindStubUpstream: UpstreamForwarding {
    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        ForwardResult(statusCode: 200, headers: [], body: Data())
    }
}
