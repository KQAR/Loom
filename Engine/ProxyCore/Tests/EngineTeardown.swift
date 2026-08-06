import Foundation
import LoomSharedModels
import NIOPosix
@testable import LoomProxyCore

/// Stop an engine a test started, **deterministically**, before the test returns.
///
/// The pattern this replaces was `defer { Task { await engine.stop() } }`. That
/// `Task` is unstructured: the test returns immediately and `stop()` runs *later* —
/// in practice during the *next* test, closing channels and tearing down an
/// event-loop group while another test was using one. Thread Sanitizer caught it as
/// a data race in NIO's continuation machinery plus an `abort()`, attributed to a
/// test that had already finished:
///
///     ✗ theHostHeaderFollowsTheUpstreamByDefault() — Crash: xctest at
///       closure #1 in $defer #1 () in aRequestToTheEndpointIsForwardedToTheUpstream()
///
/// Note which test is named in each half — that mismatch is the whole tell, and it
/// is why the non-TSan runs looked fine for two rounds: without the sanitizer the
/// late teardown usually lands in a gap where nothing else is mid-flight.
///
/// `stopForTest()` is called at the end of the body instead. A test that *throws*
/// (a failed `#require`) skips it and leaks the engine for the rest of the process,
/// which is deliberate and strictly better than the alternative: the ports are
/// ephemeral and the group is the engine's own, so a leak costs a couple of idle
/// threads, while a late teardown reaches into a *different* test's run.
/// It calls `shutdown()`, not `stop()`, and that difference is the second half of the
/// same story. `stop()` closes the listeners but keeps the event-loop group alive so the
/// proxy can be switched back on; nothing ever shut the group down, so every engine a
/// test built left two event-loop threads running for the rest of the process. Several
/// hundred engines per run means several hundred loops still executing against memory
/// that has been freed and reused — the shape of the intermittent ThreadSanitizer
/// report this suite has carried (a race on a continuation heap block, blamed on
/// whichever test happened to be running).
///
/// A test's engine is finished when the test is, so terminal teardown is exactly right
/// here — and it is what keeps the sanitizer's report about *this* test rather than
/// about the wreckage of the previous three hundred.
extension ProxyEngine {
    func stopForTest() async {
        await shutdown()
    }
}

/// Run an async teardown from a **synchronous** `defer`, and wait for it.
///
/// For the suites whose tests are synchronous (they drive raw NIO clients and block on
/// futures), where `await` isn't available in the `defer` at all. Blocking here is safe
/// for the same reason it is in those suites' own bridges: the body runs on the
/// cooperative pool, not on this thread.
///
/// Two suites already carry a private copy of this; they keep theirs rather than being
/// churned, but a third copy is where a pattern starts to rot, so new callers use this.
func runBlockingVoid(_ body: @escaping @Sendable () async -> Void) {
    let semaphore = DispatchSemaphore(value: 0)
    Task { await body(); semaphore.signal() }
    semaphore.wait()
}

/// Wait — bounded — for a captured flow that satisfies `condition`.
///
/// A test client receiving its response does **not** mean the store holds the
/// finished flow. Capture completes on the event loop after the last byte goes back
/// to the client, so reading `recentFlows()` on the very next line is a race: the
/// flow can be missing entirely, or present with `response.body` still nil.
///
/// It went unnoticed for as long as CI restored built products and the runner sat
/// idle between compiles. Removing the DerivedData cache (every run now compiles the
/// world, on a busier machine) turned it into a real failure —
/// `interceptsTLSOverSOCKS` first, with the flow found but its body nil.
///
/// Waiting rather than sleeping a fixed amount, per this repo's standing preference
/// for fixing a timing flake over tuning one: a sleep long enough today is a number
/// that rots, and one too short fails as a mystery. This returns the moment the
/// condition holds and gives up at `timeout`, so a genuine capture regression still
/// fails — at the assertion that wanted the flow, by name.
func awaitFlow(
    from engine: ProxyEngine,
    timeout: TimeInterval = 5,
    where condition: @escaping @Sendable (Flow) -> Bool
) async -> Flow? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let flow = await engine.recentFlows(limit: 50).first(where: condition) { return flow }
        try? await Task.sleep(nanoseconds: 10_000_000)
    } while Date() < deadline
    return nil
}

/// The same wait for the synchronous suites — they drive raw NIO clients and block on
/// futures, so `await` isn't available at the call site. Blocking here is safe for the
/// reason `runBlockingVoid` gives: the body runs on the cooperative pool, not here.
func awaitFlowBlocking(
    from engine: ProxyEngine,
    timeout: TimeInterval = 5,
    where condition: @escaping @Sendable (Flow) -> Bool
) -> Flow? {
    let box = FlowBox()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        box.value = await awaitFlow(from: engine, timeout: timeout, where: condition)
        semaphore.signal()
    }
    semaphore.wait()
    return box.value
}

/// Carries one flow across the semaphore. `@unchecked Sendable` because the write and
/// the read are ordered by that semaphore, which the compiler can't see.
private final class FlowBox: @unchecked Sendable {
    var value: Flow?
}

/// Shut a test-local event-loop group down, blocking until its threads are gone.
///
/// `MultiThreadedEventLoopGroup.syncShutdownGracefully()` is `@available(*, noasync)`
/// because it blocks the calling thread, and a `defer` inside an `async` test body
/// inherits that async context — so under the Swift 6 language mode every
/// `defer { try? group.syncShutdownGracefully() }` in this suite became an error.
///
/// Wrapping the call in a synchronous function is the escape Swift documents for
/// `noasync`, and here it is the *correct* escape rather than a silencer: blocking is
/// exactly what teardown wants. The two alternatives are both worse. `Task { try await
/// group.shutdownGracefully() }` is unstructured — the test returns immediately and the
/// group dies during the *next* test, which is the precise defect `stopForTest()` above
/// exists to document. `group.shutdownGracefully { _ in }` returns before the threads
/// are reclaimed, so several hundred tests leave several hundred loops running.
func shutdownBlocking(_ group: MultiThreadedEventLoopGroup) {
    try? group.syncShutdownGracefully()
}
