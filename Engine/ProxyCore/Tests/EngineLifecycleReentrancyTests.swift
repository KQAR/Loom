import Testing
import Foundation
import LoomSharedModels
@testable import LoomProxyCore

/// `ProxyEngine` is an actor, so every `await` inside a lifecycle method is a
/// suspension another caller can slip through. `start()` already guards this by
/// claiming `running` before its first await; these tests pin the same property
/// for the other lifecycle methods, which did not.
@Suite("Engine lifecycle reentrancy", .timeLimit(.minutes(1)))
struct EngineLifecycleReentrancyTests {
    private func makeEngine() -> ProxyEngine {
        ProxyEngine(forwarder: LifecycleStubUpstream(), caStore: InMemoryCAStore())
    }

    /// Two concurrent `stop()` calls must tear the server down once. Before the
    /// `stopping` flag, both passed the `guard running` check (because `running`
    /// stays true across the awaits so a reentrant `start` still bails) and both
    /// went on to call `server.stop()`.
    @Test func concurrentStop_tearsDownOnce() async throws {
        let engine = makeEngine()
        _ = try await engine.start(port: 0)
        #expect(await engine.isRunning)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { await engine.stop() }
            }
        }

        #expect(await engine.isRunning == false)
        // And the engine is still usable afterwards — a double teardown would have
        // left the event-loop group in a state where this rebind fails.
        let port = try await engine.start(port: 0)
        #expect(port > 0)
        await engine.stopForTest()
    }

    /// `stop()` on an engine that was never started is a no-op, not a crash.
    @Test func stopWithoutStart_isANoOp() async {
        let engine = makeEngine()
        await engine.stop()
        #expect(await engine.isRunning == false)
        await engine.stopForTest()
    }

    /// Concurrent `startPhoneOnboarding()` calls must not both build a provisioning
    /// server: they would race for the same port and leave `provisioning` pointing
    /// at a server that had already been stopped. The loser now fails cleanly.
    ///
    /// Skipped when the machine has no LAN IPv4 (CI containers, Wi-Fi off) — phone
    /// onboarding legitimately can't start there.
    ///
    /// The skip is a trait, evaluated before the body runs. It used to be
    /// `try #require(LANAddress.primaryIPv4() != nil)`, which in Swift Testing
    /// records an issue and *fails* — so on precisely the LAN-less environment this
    /// comment describes, the test went red instead of standing down.
    @Test(.enabled(if: LANAddress.primaryIPv4() != nil, "needs a LAN IPv4 address"))
    func concurrentPhoneOnboarding_onlyOneWins() async throws {
        let engine = makeEngine()
        _ = try await engine.start(port: 0)

        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<3 {
                group.addTask {
                    do { _ = try await engine.startPhoneOnboarding(provisioningPort: 0); return true }
                    catch { return false }
                }
            }
            var results: [Bool] = []
            for await ok in group { results.append(ok) }
            return results
        }

        #expect(outcomes.filter { $0 }.count == 1, "exactly one concurrent start may win")
        // The winner's server is the live one, so onboarding info is published.
        #expect(await engine.phoneOnboardingInfo() != nil)
        await engine.stopPhoneOnboarding()
        await engine.stopForTest()
    }
}

private struct LifecycleStubUpstream: UpstreamForwarding {
    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        ForwardResult(statusCode: 200, headers: [], body: Data())
    }
}
