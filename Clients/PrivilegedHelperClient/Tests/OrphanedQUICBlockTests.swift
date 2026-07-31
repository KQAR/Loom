import Testing
import Foundation
import LoomSharedModels
@testable import PrivilegedHelperClient

/// A crash skips the quit-time cleanup, so a QUIC (pf) block can outlive the
/// session that created it. That leaves all outbound UDP/443 dropped machine-wide,
/// and no UI path could undo it — the panel's toggle only runs the enable branch
/// while the proxy is off, so the pf restore was unreachable and the user's only
/// escape was `sudo pfctl -f /etc/pf.conf`.
///
/// The decision is separated from the effect (`restoreOrphanedQUICBlock`, which
/// runs pfctl and may escalate) so it can be pinned without a machine that happens
/// to have a proxy set — and without any test ever reaching an auth prompt.
@Suite struct OrphanedQUICBlockTests {
    /// A throwaway domain so these never read or clobber the real `com.loom.quicBlocked`.
    private func scratchDefaults() -> UserDefaults {
        let suite = "com.loom.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func noRecordedBlock_isNothingToClean() {
        // The common launch: cheap, silent, no prompt.
        let defaults = scratchDefaults()
        #expect(SystemProxyApplier.hasOrphanedQUICBlock(routing: .off, defaults: defaults) == false)
    }

    @Test func aBlockIsOrphanedWhenTheProxyIsOff() {
        let defaults = scratchDefaults()
        defaults.set(true, forKey: SystemProxyApplier.quicBlockedKey)
        #expect(SystemProxyApplier.hasOrphanedQUICBlock(routing: .off, defaults: defaults))
    }

    @Test func aBlockIsOrphanedWhenAnotherAppTookTheProxy() {
        // The worst case, and the one with no exit before this: Loom crashed, Charles
        // took the setting, and UDP/443 stays dropped for everything on the machine.
        let defaults = scratchDefaults()
        defaults.set(true, forKey: SystemProxyApplier.quicBlockedKey)
        #expect(SystemProxyApplier.hasOrphanedQUICBlock(
            routing: .other(host: "127.0.0.1", port: 8888), defaults: defaults
        ))
    }

    @Test func aBlockIsNotOrphanedWhileLoomHoldsTheProxy() {
        // It belongs to this session. Clearing it would silently stop capturing
        // browser HTTP/3 — the thing the block exists to enable.
        let defaults = scratchDefaults()
        defaults.set(true, forKey: SystemProxyApplier.quicBlockedKey)
        #expect(SystemProxyApplier.hasOrphanedQUICBlock(routing: .loom, defaults: defaults) == false)
    }
}
