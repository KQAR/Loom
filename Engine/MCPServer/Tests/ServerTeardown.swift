@testable import MCPServer

/// Stop a server a test started, **deterministically**, before the test returns.
///
/// The sibling of `ProxyEngine.stopForTest()` in `ProxyCoreTests/EngineTeardown.swift`,
/// and it exists for the same reason that one does — this bundle just took longer to
/// get there, because the CI Thread Sanitizer job is scoped to `ProxyCoreTests` and so
/// could never have caught it here.
///
/// The pattern this replaces was `defer { Task { await server.stop() } }`, at 26 sites.
/// That `Task` is unstructured: the test returns immediately and `stop()` runs *later* —
/// in practice during the *next* test, closing a channel while another test is binding
/// one. In ProxyCore, Thread Sanitizer caught the same shape as a race in NIO's
/// continuation machinery plus an `abort()`, attributed to a test that had already
/// finished; read that file's comment for the transcript.
///
/// It calls `shutdown()`, not `stop()`, and that difference is the second half of the
/// story. `stop()` closes the listener but keeps the event-loop group alive so the app's
/// one server can be toggled; nothing ever shut the group down, so every server a test
/// built left an event-loop thread running for the rest of the process.
///
/// Called at the end of the body rather than from a `defer`, because `defer` cannot
/// `await`. A test that *throws* (a failed `#require`) therefore skips it and leaks the
/// server for the rest of the process, which is deliberate and strictly better than the
/// alternative: the port is ephemeral and the group is the server's own, so a leak costs
/// one idle thread, while a late teardown reaches into a *different* test's run.
extension MCPServer {
    func stopForTest() async {
        await shutdown()
    }
}
