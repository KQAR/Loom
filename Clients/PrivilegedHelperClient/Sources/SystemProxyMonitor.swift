import Foundation
import SystemConfiguration
import LoomSharedModels

/// Watches the *effective* system proxy and reports every change.
///
/// Loom used to read this state only three times: at boot, right after applying its
/// own change, and on quit. So if Charles or whistle took the proxy while Loom's
/// panel was open, the panel kept claiming "on" until the human closed and reopened
/// it — a stale switch for a setting that decides whether anything gets captured at
/// all. `SCDynamicStore` notifies on the proxy key, so there is no reason to poll and
/// no reason to be wrong in between.
enum SystemProxyMonitor {
    /// The current effective HTTP/HTTPS proxy settings. Reading needs no privileges.
    static func snapshot() -> SystemProxySnapshot {
        guard let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return .off }
        return snapshot(from: proxies)
    }

    /// Bridge an `SCDynamicStoreCopyProxies` dictionary. Split out so the key names —
    /// the part that silently breaks if it drifts — are exercised by a test that
    /// doesn't need a real dynamic store.
    static func snapshot(from proxies: [String: Any]) -> SystemProxySnapshot {
        func enabled(_ key: String) -> Bool { (proxies[key] as? Int ?? 0) == 1 }
        return SystemProxySnapshot(
            httpEnabled: enabled("HTTPEnable"),
            httpHost: proxies["HTTPProxy"] as? String ?? "",
            httpPort: proxies["HTTPPort"] as? Int ?? 0,
            httpsEnabled: enabled("HTTPSEnable"),
            httpsHost: proxies["HTTPSProxy"] as? String ?? "",
            httpsPort: proxies["HTTPSPort"] as? Int ?? 0
        )
    }

    /// Every change to the effective proxy settings, starting with the current value
    /// so a subscriber never has to seed itself separately.
    ///
    /// Unbounded buffering on purpose: these arrive at human speed (someone toggling
    /// a proxy app), the consumer is a reducer that drains immediately, and dropping
    /// the *newest* value — what `.bufferingNewest(1)` would do under contention — is
    /// the one outcome that would leave the UI wrong, which is the bug being fixed.
    static func snapshots() -> AsyncStream<SystemProxySnapshot> {
        AsyncStream { continuation in
            let sink = Sink(continuation)
            // +1 retain handed to the C context; balanced in onTermination.
            let info = Unmanaged.passRetained(sink).toOpaque()
            var context = SCDynamicStoreContext(
                version: 0, info: info, retain: nil, release: nil, copyDescription: nil
            )
            let callback: SCDynamicStoreCallBack = { _, _, info in
                guard let info else { return }
                Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
                    .continuation.yield(SystemProxyMonitor.snapshot())
            }
            guard let store = SCDynamicStoreCreate(
                nil, "com.loom.system-proxy-monitor" as CFString, callback, &context
            ) else {
                Unmanaged<Sink>.fromOpaque(info).release()
                // Fail open and honest: emit the current value once so the UI is at
                // least right at subscribe time, then end rather than pretend to watch.
                continuation.yield(snapshot())
                continuation.finish()
                return
            }
            let key = SCDynamicStoreKeyCreateProxies(nil)
            SCDynamicStoreSetNotificationKeys(store, [key] as CFArray, nil)
            SCDynamicStoreSetDispatchQueue(store, DispatchQueue(label: "com.loom.system-proxy-monitor"))

            let teardown = Teardown(store: store, info: info)
            continuation.onTermination = { _ in teardown.run() }
            continuation.yield(snapshot())
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

    /// Box for the continuation so it can travel through the C callback's `void *`.
    /// `@unchecked Sendable`: the only member is a continuation, which is itself
    /// thread-safe, and it is never mutated after init.
    private final class Sink: @unchecked Sendable {
        let continuation: AsyncStream<SystemProxySnapshot>.Continuation
        init(_ continuation: AsyncStream<SystemProxySnapshot>.Continuation) {
            self.continuation = continuation
        }
    }
}
