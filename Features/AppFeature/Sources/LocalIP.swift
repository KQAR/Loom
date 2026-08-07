import Foundation
import LoomSharedModels
import Synchronization
import SystemConfiguration

/// Watches this machine's primary LAN IPv4 address.
///
/// The resolve itself is `LANAddress.primaryIPv4()` in SharedModels — this had a
/// byte-for-byte copy of it, which was fine while the two answers were only ever
/// displayed, and stopped being fine once the app started comparing its answer
/// with the address the engine published in the QR.
enum LocalIP {
    /// The primary LAN IPv4 every time the machine's network configuration
    /// changes, starting with the current value so a subscriber never has to seed
    /// itself separately.
    ///
    /// This used to be resolved exactly once, in the boot effect. An address is not
    /// a boot-time constant: joining a different Wi-Fi network, a DHCP renewal, a
    /// cable, a VPN coming up — each of them changes the number a phone has to be
    /// pointed at, and none of them changed the number Loom displayed. The stale
    /// value fails the same way a wrong one does, and the phone-onboarding QR is
    /// generated from the *engine's* own resolve, so the two could disagree.
    ///
    /// Same `SCDynamicStore` mechanism as `SystemProxyMonitor` — notification, not
    /// polling — but keyed on the IPv4 entities rather than the proxy dictionary:
    /// the global IPv4 key (which interface is primary) plus a pattern matching
    /// every interface's IPv4 state (an address changing under a fixed primary).
    ///
    /// Unbounded buffering, and consecutive duplicates are dropped here rather than
    /// by the consumer: a single Wi-Fi join emits several times as the
    /// configuration settles, and most of those carry the same address.
    static func addresses() -> AsyncStream<String?> {
        AsyncStream { continuation in
            let sink = Sink(continuation)
            // +1 retain handed to the C context; balanced in onTermination.
            let info = Unmanaged.passRetained(sink).toOpaque()
            var context = SCDynamicStoreContext(
                version: 0, info: info, retain: nil, release: nil, copyDescription: nil
            )
            let callback: SCDynamicStoreCallBack = { _, _, info in
                guard let info else { return }
                Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue().emit(LANAddress.primaryIPv4())
            }
            guard let store = SCDynamicStoreCreate(
                nil, "com.loom.local-ip-monitor" as CFString, callback, &context
            ) else {
                Unmanaged<Sink>.fromOpaque(info).release()
                // Fail open and honest: emit the current value once so the UI is at
                // least right at subscribe time, then end rather than pretend to watch.
                continuation.yield(LANAddress.primaryIPv4())
                continuation.finish()
                return
            }
            let global = SCDynamicStoreKeyCreateNetworkGlobalEntity(
                nil, kSCDynamicStoreDomainState, kSCEntNetIPv4
            )
            let perInterface = SCDynamicStoreKeyCreateNetworkInterfaceEntity(
                nil, kSCDynamicStoreDomainState, kSCCompAnyRegex, kSCEntNetIPv4
            )
            SCDynamicStoreSetNotificationKeys(store, [global] as CFArray, [perInterface] as CFArray)
            SCDynamicStoreSetDispatchQueue(store, DispatchQueue(label: "com.loom.local-ip-monitor"))

            let teardown = Teardown(store: store, info: info)
            continuation.onTermination = { _ in teardown.run() }
            sink.emit(LANAddress.primaryIPv4())
        }
    }

    /// Carries the two C handles the termination closure needs, which is a `@Sendable`
    /// boundary neither of them can cross on its own: `SCDynamicStore` is a CF type
    /// with no `Sendable` conformance and `info` is a raw pointer.
    ///
    /// `@unchecked Sendable` is honest here because of *when* this runs, not what it
    /// holds: `onTermination` fires once, and its two steps are ordered on purpose —
    /// detach the dispatch queue first, so the queue can't fire into a released sink,
    /// then drop the retain the C context was handed.
    private final class Teardown: @unchecked Sendable {
        private let store: SCDynamicStore
        private let info: UnsafeMutableRawPointer

        init(store: SCDynamicStore, info: UnsafeMutableRawPointer) {
            self.store = store
            self.info = info
        }

        func run() {
            SCDynamicStoreSetDispatchQueue(store, nil)
            Unmanaged<Sink>.fromOpaque(info).release()
        }
    }

    /// Box for the continuation so it can travel through the C callback's `void *`,
    /// plus the last value emitted so repeats can be dropped. The dedupe state is
    /// held in a `Mutex` rather than left bare: the store's callbacks arrive on its
    /// dispatch queue while the initial `emit` runs on the subscriber's thread.
    private final class Sink: Sendable {
        private let continuation: AsyncStream<String?>.Continuation
        private let last = Mutex<String??>(nil)   // outer nil = nothing emitted yet

        init(_ continuation: AsyncStream<String?>.Continuation) {
            self.continuation = continuation
        }

        func emit(_ ip: String?) {
            let changed = last.withLock { last -> Bool in
                guard last != .some(ip) else { return false }
                last = .some(ip)
                return true
            }
            if changed { continuation.yield(ip) }
        }
    }
}
