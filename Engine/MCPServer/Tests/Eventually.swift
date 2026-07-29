import Testing
import Foundation

/// Wait for a condition instead of sleeping a fixed time.
///
/// The blocking tools are all shaped the same way in a test: start the call, let it
/// subscribe, then push the thing it's waiting for. Sleeping a fixed 50–100 ms to
/// cover "let it subscribe" is a bet on scheduler latency — when the push wins the
/// race the tool misses the event, falls through to its own timeout, and the test
/// fails claiming `timedOut: true` for a reason that has nothing to do with the
/// behaviour under test.
///
/// Polling a real signal instead fails fast on an actual regression and doesn't
/// care how loaded the machine is. Lives here rather than inside one suite so every
/// suite waits the same way — `MCPServerTransportTests` had the only copy, and
/// `WaitToolTests` (eight sleeps) never got to use it.
@MainActor
func eventually(
    _ description: String,
    timeout: TimeInterval = 3,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    Issue.record("timed out waiting for: \(description)")
}
