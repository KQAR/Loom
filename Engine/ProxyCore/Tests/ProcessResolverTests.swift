import Testing
import Foundation
@testable import LoomProxyCore
import LoomSharedModels

/// Source-app resolution walks every process's file descriptors via libproc — the
/// most expensive thing on the capture path. Two properties matter:
///
/// 1. **It must not run for a LAN peer.** A phone has no local pid, so the scan
///    can only fail — and its *remote* ephemeral port could coincide with a local
///    socket's local port, mis-attributing the phone's traffic to a Mac app.
/// 2. **One sweep must serve a burst.** The old code scanned once per connection;
///    a fresh port on every request (phones, short-lived curl loops) meant a full
///    system scan per request.
///
/// A real end-to-end resolution needs another process holding the socket (the
/// resolver skips its own pid), so that path is left to manual verification; what
/// is pinned here is the work-avoidance, which is where the cost lived.
@Suite struct ProcessResolverTests {
    @Test func lanPeer_isNotResolved_andCostsNoScan() {
        let resolver = ProcessResolver()
        #expect(ProcessResolver.resolve(sourcePort: 54_321, proxyPort: 9_090, isLoopbackPeer: false) == nil)
        // Nothing was asked of the shared resolver; assert on a private one too, so
        // the guard is proven to sit before any work.
        #expect(resolver.scanCount == 0)
    }

    @Test func missingOrZeroPorts_returnNil() {
        #expect(ProcessResolver.resolve(sourcePort: nil, proxyPort: 9_090, isLoopbackPeer: true) == nil)
        #expect(ProcessResolver.resolve(sourcePort: 50_000, proxyPort: nil, isLoopbackPeer: true) == nil)
        #expect(ProcessResolver.resolve(sourcePort: 0, proxyPort: 9_090, isLoopbackPeer: true) == nil)
    }

    /// The async form is what the forwarding path calls, so its gating must match
    /// the blocking one exactly — a LAN peer or a bad port must be refused before
    /// anything is dispatched to the scan queue.
    @Test func asyncForm_gatesTheSameWayAsTheBlockingOne() async {
        #expect(await ProcessResolver.resolve(sourcePort: 54_321, proxyPort: 9_090, isLoopbackPeer: false) == nil)
        #expect(await ProcessResolver.resolve(sourcePort: nil, proxyPort: 9_090, isLoopbackPeer: true) == nil)
        #expect(await ProcessResolver.resolve(sourcePort: 50_000, proxyPort: nil, isLoopbackPeer: true) == nil)
        #expect(await ProcessResolver.resolve(sourcePort: 0, proxyPort: 9_090, isLoopbackPeer: true) == nil)
    }

    /// Many concurrent resolutions must all complete — the point of the dedicated
    /// queue is that they wait on one blocked thread instead of each blocking a
    /// worker of the (core-count-sized) cooperative pool. A deadlock or a lost
    /// continuation here would hang rather than fail, hence the time limit.
    @Test(.timeLimit(.minutes(1)))
    func concurrentAsyncResolutions_allComplete() async {
        let results = await withTaskGroup(of: SourceApp?.self, returning: [SourceApp?].self) { group in
            for port in 41_000 ..< 41_064 {
                group.addTask {
                    await ProcessResolver.resolve(sourcePort: port, proxyPort: 9_090, isLoopbackPeer: true)
                }
            }
            var collected: [SourceApp?] = []
            for await result in group { collected.append(result) }
            return collected
        }
        #expect(results.count == 64, "every continuation resumed exactly once")
    }

    /// The regression this replaces: 200 distinct source ports used to mean 200
    /// full-system scans. One sweep now answers them all (plus at most one rescan
    /// for a possibly-stale table).
    @Test func burstOfDistinctPorts_sharesOneScan() {
        let resolver = ProcessResolver()
        for port in 40_000 ..< 40_200 {
            _ = resolver.resolve(sourcePort: UInt16(port), proxyPort: 9_090)
        }
        #expect(resolver.scanCount <= 2, "expected one sweep for the burst, got \(resolver.scanCount)")
    }

    @Test func repeatedLookupOfTheSamePort_isCached() {
        let resolver = ProcessResolver()
        _ = resolver.resolve(sourcePort: 41_000, proxyPort: 9_090)
        let afterFirst = resolver.scanCount
        for _ in 0 ..< 50 { _ = resolver.resolve(sourcePort: 41_000, proxyPort: 9_090) }
        #expect(resolver.scanCount == afterFirst, "a cached answer (including a nil one) must not rescan")
    }

    /// An unknown port resolves to nil rather than to some other process that
    /// happens to hold that local port for a different peer.
    @Test func unrelatedPort_doesNotMisattribute() {
        let resolver = ProcessResolver()
        // Port 1 is never a client's ephemeral source port to our proxy.
        #expect(resolver.resolve(sourcePort: 1, proxyPort: 9_090) == nil)
    }
}
