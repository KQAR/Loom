import Foundation
import NIOCore
import NIOEmbedded
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// Per-exchange costs on paths every capture pays, each of which grew with something
/// it should not have.
@Suite("Capture hot path")
struct CaptureHotPathTests {
    /// A full ring trims below its capacity, so the shift `removeFirst` costs is paid
    /// once per 2.5 % of capacity rather than once per flow — and it still never holds
    /// more than `capacity`.
    @Test func aFullRingTrimsBelowCapacityAndNeverAboveIt() async {
        let store = FlowStore(capacity: 80)
        var peak = 0
        for n in 0 ..< 200 {
            await store.upsert(Flow(
                request: CapturedRequest(method: "GET", url: "https://h.test/\(n)", headers: []),
                startedAt: Date()
            ))
            peak = max(peak, await store.count)
        }
        let final = await store.count
        #expect(peak == 80, "the ring must never exceed its capacity")
        #expect(final >= 78 && final <= 80)
    }

    /// One registration per client channel: an exchange that finishes takes itself
    /// out, and the channel closing cancels whatever is still in flight.
    @Test func aClosingClientCancelsItsInFlightRelayAndFinishedOnesLeaveNothing() async throws {
        let watch = ClientCloseWatch()
        // The async testing channel, not `EmbeddedChannel`: the latter's loop only
        // runs when driven, and an async test awaiting its futures waits forever.
        let channel = NIOAsyncTestingChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1))

        for _ in 0 ..< 1_000 {
            let done = Task<Void, Never> {}
            let token = watch.track(done, on: channel)
            await done.value
            watch.untrack(token)
        }
        #expect(watch.trackedCount(on: channel) == 0, "finished exchanges must not accumulate on a live connection")

        let inFlight = Task<Void, Never> {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        _ = watch.track(inFlight, on: channel)
        try await channel.close()
        await inFlight.value // returns only because the close cancelled it
        #expect(inFlight.isCancelled)
    }
}
