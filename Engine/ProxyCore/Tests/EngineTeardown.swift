import Foundation
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
func runBlockingVoid(_ body: @escaping () async -> Void) {
    let semaphore = DispatchSemaphore(value: 0)
    Task { await body(); semaphore.signal() }
    semaphore.wait()
}
