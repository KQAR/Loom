import Foundation
import Testing
@testable import LoomProxyCore

/// `ProxyEngine.proxyPort` must answer exactly what `status().port` does, without
/// being `status()`.
///
/// The reason it exists is cost, not correctness: `status()` reaches `FlowStore`
/// four times (`count`, `retainedCount`, `isRecording`, `droppedFlowCount`) plus a
/// `RefusalLog` snapshot, and `FlowStore` is the actor every capture write queues
/// on. Five callers wanted one `Int` and paid all of it — including
/// `applicationShouldTerminate`, which reads the port to unset the system proxy
/// while the capture path is still draining, and holds AppKit on
/// `.terminateLater` in the meantime.
///
/// A test cannot observe "did not hop onto an actor", so what is pinned here is the
/// property that makes the cheap accessor safe to prefer: the two answers are the
/// same one, before a listener exists and after — including across a rebind, which
/// is the case a value cached at construction would get wrong (phone onboarding
/// moves the listener to `0.0.0.0`, and `start(port: 0)` never returns the default).
@Suite("The port accessor answers what status() does", .timeLimit(.minutes(1)))
struct ProxyPortAccessorTests {
    private func makeEngine() -> ProxyEngine {
        ProxyEngine(forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore())
    }

    @Test func beforeStart_bothReportTheDefault() async {
        let engine = makeEngine()
        #expect(await engine.proxyPort == 9090)
        #expect(await engine.proxyPort == engine.status().port)
        await engine.stopForTest()
    }

    @Test func afterStart_bothReportTheBoundPort() async throws {
        let engine = makeEngine()
        let bound = try await engine.start(port: 0)

        #expect(bound != 9090, "an OS-assigned port is the case a hardcoded default would hide")
        #expect(await engine.proxyPort == bound)
        #expect(await engine.proxyPort == engine.status().port)
        await engine.stopForTest()
    }

    @Test func acrossARebind_bothFollowTheNewPort() async throws {
        let engine = makeEngine()
        _ = try await engine.start(port: 0)
        await engine.stop()

        let second = try await engine.start(port: 0)
        #expect(await engine.proxyPort == second)
        #expect(await engine.proxyPort == engine.status().port)
        await engine.stopForTest()
    }
}
