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
extension ProxyEngine {
    func stopForTest() async {
        await stop()
    }
}
