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

/// Moving the listener — the one write path shared by the toolbar's address editor
/// and the `set_proxy_port` tool.
@Suite("Changing the listen port", .timeLimit(.minutes(1)))
struct ListenPortChangeTests {
    private func makeEngine() -> ProxyEngine {
        ProxyEngine(forwarder: BindStubUpstream(), caStore: InMemoryCAStore())
    }

    /// The whole reason this is not a stop-then-start: a `start()` binds loopback, so
    /// restarting the proxy to change its port silently closed it to the LAN and a
    /// phone that was capturing stopped reaching it.
    @Test(.enabled(if: LANAddress.primaryIPv4() != nil, "needs a LAN IPv4 address"))
    func changingThePort_keepsTheInterface() async throws {
        let engine = makeEngine()
        _ = try await engine.start(port: 0)
        _ = try? await engine.startPhoneOnboarding(provisioningPort: 0)
        try #require(await engine.status().listenHost == "0.0.0.0", "needs the LAN binding to test it survives")

        let moved = try await engine.setListenPort(0, socksPort: nil)
        #expect(moved.listenHost == "0.0.0.0", "the interface must survive a port change")
        #expect(moved.isRunning)
        await engine.stopForTest()
    }

    /// A refused move leaves a **working proxy**, not a stopped one — the stop has
    /// already happened by the time the new bind is attempted.
    @Test func aPortAlreadyHeld_isRefusedAndTheListenerStays() async throws {
        let engine = makeEngine()
        let port = try await engine.start(port: 0)

        let held = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let taken = held.localAddress?.port ?? 0

        await #expect(throws: ProxyControlError.self) {
            _ = try await engine.setListenPort(taken, socksPort: nil)
        }
        let after = await engine.status()
        #expect(after.isRunning)
        #expect(after.port == port, "the listener stays where it was serving")
        // And is still accepting, which a status flag cannot promise on its own.
        let probe = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(host: "127.0.0.1", port: port)
            .get()
        try await probe.close()

        await engine.stopForTest()
        try await held.close()
    }

    /// Refused before anything is touched, because taking it would disconnect the
    /// agent that asked.
    @Test func theMCPControlPort_isRefused() async throws {
        ReservedPorts.shared.reserve(9092, holder: "Loom's MCP control port")
        defer { ReservedPorts.shared.release(9092) }
        let engine = makeEngine()
        let port = try await engine.start(port: 0)

        for candidate in [9092, 9091] {  // the port itself, and the SOCKS neighbour
            await #expect(throws: ProxyControlError.self) {
                _ = try await engine.setListenPort(candidate, socksPort: candidate + 1)
            }
        }
        #expect(await engine.status().port == port)
        await engine.stopForTest()
    }

    /// A stopped proxy has no listener to move, and reporting a port nothing is on
    /// would be worse than refusing.
    @Test func aStoppedProxy_refusesRatherThanPretending() async {
        let engine = makeEngine()
        await #expect(throws: ProxyControlError.self) {
            _ = try await engine.setListenPort(9099, socksPort: 9100)
        }
        await engine.stopForTest()
    }
}

/// `isRunning: false` and `lanReachable: false` are answers with no reason attached:
/// a stopped proxy is either one somebody switched off or one whose port was taken,
/// and a loopback-only listener is either LAN device connection off or a LAN bind
/// that was refused. `ProxyStatus.listenerError` is what tells a setting from a
/// failure, and it is the agent's half of what the console has been showing.
@Suite("The status explains its own listener", .timeLimit(.minutes(1)))
struct ListenerErrorReportingTests {
    private func makeEngine() -> ProxyEngine {
        ProxyEngine(forwarder: BindStubUpstream(), caStore: InMemoryCAStore())
    }

    @Test func aStartThatCouldNotBind_isExplainedInTheStatus() async throws {
        let held = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let taken = held.localAddress?.port ?? 0

        let engine = makeEngine()
        _ = try? await engine.start(port: taken)

        let status = await engine.status()
        #expect(status.isRunning == false)
        let reason = try #require(status.listenerError, "a stopped proxy must say why it is stopped")
        #expect(reason.contains("\(taken)"))
        #expect(reason.contains("already in use"))

        await engine.stopForTest()
        try await held.close()
    }

    /// Cleared by the bind that lands — an entry that outlives its condition is the
    /// same defect as no entry, pointed the other way.
    @Test func aStartThatLands_clearsIt() async throws {
        let held = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let engine = makeEngine()
        _ = try? await engine.start(port: held.localAddress?.port ?? 0)
        #expect(await engine.status().listenerError != nil)

        _ = try await engine.start(port: 0)
        #expect(await engine.status().listenerError == nil, "a bind that lands ends the condition")

        await engine.stopForTest()
        try await held.close()
    }

    /// A refused *port change* leaves the listener exactly where it should be, so it
    /// must **not** leave a standing complaint behind — the caller already got the
    /// error, and a status that keeps reporting a handled failure is noise that
    /// outlives its cause.
    @Test func aRefusedPortChange_leavesNoStandingError() async throws {
        let engine = makeEngine()
        _ = try await engine.start(port: 0)
        let held = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0)
            .get()

        _ = try? await engine.setListenPort(held.localAddress?.port ?? 0, socksPort: nil)

        #expect(await engine.status().isRunning)
        #expect(await engine.status().listenerError == nil, "the listener is where it should be")

        await engine.stopForTest()
        try await held.close()
    }
}
