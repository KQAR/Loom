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
    ///
    /// **The trait is not enough on its own, and that cost a CI red** (run 30973370795:
    /// zero winners, no onboarding info, failed in 0.004 s — too fast to have attempted
    /// a bind). The trait is evaluated once at test discovery; `startPhoneOnboarding`
    /// reads the address again in its own body. On a runner whose network comes and goes,
    /// those two reads legitimately disagree, and all three callers then throw "no LAN
    /// IPv4" — which is the environment standing down, not a broken reentrancy guard.
    ///
    /// So the outcomes are *classified* rather than counted as booleans. It removes the
    /// flake without weakening anything: a leaked guard still shows up as two or three
    /// winners, and the non-winners now have to fail for the specific reason the guard
    /// exists rather than for any reason at all. It also makes the next failure
    /// diagnosable — the old boolean could not tell "no LAN address" from "the CA would
    /// not generate", which have identical symptoms here.
    @Test(.enabled(if: LANAddress.primaryIPv4() != nil, "needs a LAN IPv4 address"))
    func concurrentPhoneOnboarding_onlyOneWins() async throws {
        enum Outcome: Equatable {
            case won
            /// Refused by the reentrancy guard — the expected fate of the losers.
            case alreadyStarting
            /// The machine lost its LAN IPv4 between the trait and the call.
            case noLANAddress
            case other(String)
        }

        let engine = makeEngine()
        _ = try await engine.start(port: 0)

        let outcomes = await withTaskGroup(of: Outcome.self, returning: [Outcome].self) { group in
            for _ in 0..<3 {
                group.addTask {
                    do {
                        _ = try await engine.startPhoneOnboarding(provisioningPort: 0)
                        return .won
                    } catch let error as ProxyControlError {
                        guard case let .phoneOnboardingUnavailable(reason) = error else {
                            return .other(String(describing: error))
                        }
                        if reason.contains("already starting") { return .alreadyStarting }
                        if reason.contains("no LAN IPv4") { return .noLANAddress }
                        return .other(reason)
                    } catch {
                        return .other(String(describing: error))
                    }
                }
            }
            var results: [Outcome] = []
            for await outcome in group { results.append(outcome) }
            return results
        }

        // Environment stood down mid-test: nothing to assert about the guard, and
        // failing here would be reporting the runner's network as a Loom defect.
        guard outcomes.contains(where: { $0 != .noLANAddress }) else {
            await engine.stopForTest()
            return
        }

        #expect(outcomes.filter { $0 == .won }.count == 1,
                "exactly one concurrent start may win — got \(outcomes)")
        #expect(outcomes.filter { $0 == .alreadyStarting }.count == outcomes.count - 1,
                "every loser must be refused by the reentrancy guard, not by chance — got \(outcomes)")
        // The winner's server is the live one, so onboarding info is published.
        #expect(await engine.phoneOnboardingInfo() != nil)
        try? await engine.stopPhoneOnboarding()
        await engine.stopForTest()
    }
}

private struct LifecycleStubUpstream: UpstreamForwarding {
    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        ForwardResult(statusCode: 200, headers: [], body: Data())
    }
}
