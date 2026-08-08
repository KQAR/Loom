import Foundation
import Synchronization
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

// MARK: - Why there is no `runBlocking` here any more
//
// This file used to carry `runBlocking` / `runBlockingVoid` / `awaitFlowBlocking`:
// `Task { await body() }` plus `semaphore.wait()`, so that a *synchronous* test could
// drive async engine code. Their doc comment said blocking was "safe because the body
// runs on the cooperative pool, not on this thread". **That reasoning was wrong, and it
// cost the h2 suite's intermittent CI timeout.**
//
// Swift Testing runs every test body — `async` or not — as a task, i.e. *on* the
// cooperative pool. A sample of the hung process shows it plainly: a
// `com.apple.root.user-initiated-qos.cooperative` thread parked in `semaphore_wait_trap`
// inside `runBlocking`, called from a synchronous test body. So the wait blocks a
// cooperative thread, while the work it waits for needs one — `CapturedExchange.handle`
// does its forwarding and its capture inside `Task { … }`. Pool exhausted, deadlock.
//
// It only ever bit CI because the pool is as wide as the machine has cores: 12 here,
// 3–4 on `macos-latest`, with suites running in parallel. Reproduce it deterministically
// on any machine with
//
//     TEST_RUNNER_LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 xcodebuild test …
//
// which pins the pool to one thread. Before this change the h2 suite hung there for
// >10 minutes; after it, all of ProxyCoreTests passes in ~5 seconds.
//
// So: **a test body may not block waiting on engine work.** Test bodies are `async`,
// futures are awaited with `get()` (which is what NIO's `@available(*, noasync)` on
// `wait()` has been saying all along), and the engine is stopped with `stopForTest()`
// at the end of the body. The bridges are deleted rather than documented, because a
// function that cannot be called is a stronger rule than a comment.
//
// `shutdownBlocking` below is the one exception, and the difference is what it waits
// *for*: `syncShutdownGracefully()` is completed by the group's own event-loop threads,
// which never need the cooperative pool, so there is no cycle to close.

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
