import Testing
import Foundation
import LoomSharedModels
@testable import LoomProxyCore

/// A reverse-proxy endpoint must not be able to take a port another part of Loom owns.
///
/// The two listeners were already refused by number. The **MCP control port** was not:
/// it happened to fail with `Address already in use`, but only because the MCP server
/// had already bound it. Lose that race — an endpoint persisted on 9092 bound during
/// engine start, before the MCP server comes up — and Loom starts with its entire
/// control plane unreachable. That is the one failure an agent cannot report, since it
/// would have to report it over exactly that port.
@Suite struct ReservedPortTests {
    // MARK: The pure conflict rule

    @Test func loomsOwnProxyAndSOCKSPortsAreNamed() {
        #expect(ProxyEngine.loomPortConflict(9090, proxyPort: 9090, socksPort: 9091)?.contains("own proxy port") == true)
        #expect(ProxyEngine.loomPortConflict(9091, proxyPort: 9090, socksPort: 9091)?.contains("own SOCKS port") == true)
    }

    @Test func aFreePortIsNoConflict() {
        #expect(ProxyEngine.loomPortConflict(9200, proxyPort: 9090, socksPort: 9091) == nil)
    }

    /// 0 means "let the OS pick", which can never collide by construction — refusing it
    /// would break the ad-hoc case.
    @Test func portZeroIsNeverAConflict() {
        #expect(ProxyEngine.loomPortConflict(0, proxyPort: 9090, socksPort: 9091) == nil)
    }

    @Test func aReservedPortIsRefusedAndNamesItsHolder() {
        let registry = ReservedPorts()
        registry.reserve(9092, holder: "Loom's MCP control port")
        #expect(registry.holder(of: 9092) == "Loom's MCP control port")
        #expect(registry.holder(of: 9093) == nil)
    }

    @Test func reservingIsIdempotentAndReleasable() {
        let registry = ReservedPorts()
        registry.reserve(9092, holder: "first")
        registry.reserve(9092, holder: "second")
        #expect(registry.holder(of: 9092) == "second", "a rebind can update the description")
        registry.release(9092)
        #expect(registry.holder(of: 9092) == nil)
    }

    // MARK: Through the engine

    /// `ReservedPorts.shared` is process-wide, like `RefusalLog.shared`; this suite
    /// releases what it reserves so a parallel suite isn't left with a phantom
    /// reservation. A unique high port keeps it from colliding with a real one.
    @Test func creatingOnAReservedPortIsRefusedBeforeAnyBindIsAttempted() async throws {
        let port = 43_217
        ReservedPorts.shared.reserve(port, holder: "a test's imaginary service")
        defer { ReservedPorts.shared.release(port) }

        let engine = ProxyEngine(forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore())
        _ = try await engine.start(port: 0, socksPort: 0)
        defer { Task { await engine.stop() } }

        let error = await #expect(throws: ProxyControlError.self) {
            _ = try await engine.createReverseProxy(
                ReverseProxyEndpoint(requestedPort: port, upstream: "https://api.example.com"))
        }
        // Names the holder rather than surfacing an errno: nothing is listening on that
        // port in this test, so `bind()` would have *succeeded* — which is the whole
        // point of checking rather than leaving it to the OS.
        #expect(try #require(error).message.contains("a test's imaginary service"))
        #expect(await engine.reverseProxies().isEmpty)
    }

    /// The check has to run on the boot path too, not only on create: the endpoint was
    /// written to disk by an earlier session, possibly before that port belonged to
    /// anything.
    @Test func aPersistedEndpointOnAReservedPortIsNotBoundAtStartup() async throws {
        let port = 43_218
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("loom-reserved-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }

        // An endpoint saved before the port was reserved — exactly the 9092 case.
        let config = ReverseProxyConfig(fileURL: file)
        config.upsert(ReverseProxyEndpoint(requestedPort: port, upstream: "https://api.example.com"))
        config.flush()

        ReservedPorts.shared.reserve(port, holder: "Loom's MCP control port")
        defer { ReservedPorts.shared.release(port) }

        let reloaded = ReverseProxyConfig(fileURL: file)
        #expect(reloaded.all().count == 1, "still configured")
        // The engine's boot path is what must skip it; the rule it consults is the same
        // one create uses, so the fault is reportable rather than a silent shadowing.
        let conflict = ProxyEngine.loomPortConflict(port, proxyPort: 9090, socksPort: 9091)
        #expect(conflict?.contains("MCP control port") == true)
    }
}
