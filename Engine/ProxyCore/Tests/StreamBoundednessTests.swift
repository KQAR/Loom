import Testing
import Foundation
import LoomSharedModels
@testable import LoomProxyCore

/// Every in-memory collection in Loom has an explicit ceiling — the flow ring, the
/// body budget, the audit ring. An `AsyncStream` with the default buffering policy
/// is the one that didn't: a subscriber that stops consuming (a stalled UI, an MCP
/// client that opened a stream and wandered off) would grow its buffer without
/// limit while the producer yields on every exchange, every streaming update and
/// every WebSocket frame.
@Suite("Stream boundedness", .timeLimit(.minutes(1)))
struct StreamBoundednessTests {
    private func flow(_ n: Int) -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "https://api.example.test/\(n)", headers: []),
            startedAt: Date(timeIntervalSince1970: TimeInterval(n))
        )
    }

    /// A subscriber that never reads must not accumulate more than the buffer, no
    /// matter how much the producer yields.
    @Test func flowStream_slowSubscriberIsBounded() async throws {
        let store = FlowStore(capacity: 10, persistence: nil)
        let stream = await store.stream()

        // Yield well past the buffer without consuming anything.
        let produced = FlowStore.streamBuffer * 3
        for n in 0..<produced {
            await store.upsert(flow(n))
        }

        // Drain what survived. `bufferingOldest` keeps the first `streamBuffer`
        // emissions, so the count is capped — the excess was dropped, not queued.
        var received = 0
        var iterator = stream.makeAsyncIterator()
        while received < produced, let _ = await iterator.next() {
            received += 1
            if received == FlowStore.streamBuffer { break }
        }
        #expect(received == FlowStore.streamBuffer, "buffer must cap what a stalled subscriber holds")
        #expect(produced > FlowStore.streamBuffer, "the test must actually overflow the buffer")
    }

    /// A subscriber keeping up loses nothing — the bound must not cost correctness
    /// in the normal case.
    @Test func flowStream_keepingUpLosesNothing() async throws {
        let store = FlowStore(capacity: 100, persistence: nil)
        let stream = await store.stream()

        let count = 50
        let collector = Task {
            var ids: [UUID] = []
            for await flow in stream {
                ids.append(flow.id)
                if ids.count == count { break }
            }
            return ids
        }

        var sent: [UUID] = []
        for n in 0..<count {
            let f = flow(n)
            sent.append(f.id)
            await store.upsert(f)
        }

        let received = await collector.value
        #expect(received == sent, "an attentive subscriber sees every emission in order")
    }

    /// The device-count stream only ever needs its newest value, so it keeps one.
    @Test func deviceCountStream_keepsOnlyTheNewestValue() async throws {
        let store = FlowStore(capacity: 10, persistence: nil)
        let stream = await store.connectedDeviceCountStream()

        for i in 1...5 {
            await store.noteConnection(remoteIP: "192.168.1.\(i)")
        }

        // Six emissions were produced (the seeded 0 plus five devices) and none
        // consumed. `bufferingNewest(1)` means the one survivor is the *latest*
        // count — which is the only one that means anything for a live badge.
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == 5, "a stale count must not win the single slot")
    }

    @Test func auditStream_isBounded() async throws {
        let store = AuditStore(capacity: 10, persistence: nil)
        let stream = await store.stream()

        let produced = AuditStore.streamBuffer * 2
        for n in 0..<produced {
            await store.record(AuditEntry(tool: "set_rule_\(n)", succeeded: true, arguments: "{}", detail: ""))
        }

        var received = 0
        var iterator = stream.makeAsyncIterator()
        while received < produced, let _ = await iterator.next() {
            received += 1
            if received == AuditStore.streamBuffer { break }
        }
        #expect(received == AuditStore.streamBuffer)
    }
}
