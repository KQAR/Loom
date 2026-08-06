import Foundation
import LoomHelperShared
import ServiceManagement
import Synchronization

/// Where the privileged helper stands right now, from the app's side.
public enum HelperState: Equatable, Sendable {
    /// Never registered, or unregistered again.
    case notInstalled
    /// Registered, waiting for the human to allow it in System Settings → General
    /// → Login Items & Extensions. This is the *normal* result of a first install,
    /// not an error: macOS records the daemon and holds it disabled until approval.
    case requiresApproval
    /// Approved and loadable.
    case enabled
    /// Registered and approved, but not answering — launchd will not start it.
    ///
    /// This is a real state, not a transient, and it has one common cause: **the app
    /// was replaced** (a rebuild, or a Sparkle update). The registration names a
    /// binary, the new binary has a different code identity, and launchd declines to
    /// start the stale job while `SMAppService.status` still cheerfully reports
    /// `enabled`. `HelperInstall.ensureReady()` re-registers to repair exactly this;
    /// the state exists for when that doesn't work, because "approved but silent" and
    /// "never installed" need different words to the human.
    case unresponsive
    /// The bundled plist isn't there — an app built without the embed phase.
    case notFound

    /// Whether the helper is worth *attempting*. Not the same as "will answer" —
    /// that is only knowable by asking, which is what `ensureReady()` does.
    public var isUsable: Bool { self == .enabled }
}

/// Registration and connection for the root helper.
///
/// Two independent failure modes to keep apart, because they need opposite advice:
/// **not approved** (the human has a switch to flip, and this is the expected state
/// right after installing) versus **approved but unreachable** (a real fault — a
/// missing binary, a signature the daemon refuses, a stale interface). The state
/// above answers the first; a failed call answers the second.
public enum HelperInstall {
    private static var service: SMAppService { .daemon(plistName: HelperConstants.daemonPlistName) }

    /// What macOS records. Cheap, and **not** proof that the helper answers — see
    /// `ensureReady()`.
    public static func state() -> HelperState {
        let recorded: HelperState
        switch service.status {
        case .enabled: recorded = .enabled
        case .requiresApproval: recorded = .requiresApproval
        case .notRegistered: recorded = .notInstalled
        case .notFound: recorded = .notFound
        @unknown default: recorded = .notInstalled
        }
        // Report a known-silent helper as such rather than as `enabled`: the row would
        // otherwise read "on" while every toggle quietly pays for a password prompt.
        if recorded == .enabled, reachability.withLock({ $0 }) == .unreachable { return .unresponsive }
        return recorded
    }

    /// Whether the helper answered since this app launched. Cached because the repair
    /// path below costs a registration round trip, and a toggle is not the place to
    /// pay it twice.
    private enum Reachability: Sendable { case unknown, reachable, unreachable }
    private static let reachability = Lock(Reachability.unknown)

    /// Why the last probe failed, kept for the human and the agent.
    ///
    /// Without this, an unreachable helper is reported as "not answering — reinstall
    /// it", which is a guess dressed as advice: XPC has plenty to say (rejected
    /// signature, no such service, connection invalidated) and discarding it left
    /// *me* debugging by process-watching. `os_log` alone is not enough — same rule as
    /// everywhere else in this codebase, and the reason it is on `get_proxy_status`
    /// too.
    public private(set) static var lastFailureReason: String? {
        get { failureReason.withLock { $0 } }
        set { failureReason.withLock { $0 = newValue } }
    }
    private static let failureReason = Lock<String?>(nil)

    /// Ask the helper whether it is there, repairing a stale registration once.
    ///
    /// **The failure this exists for**: replacing the app (a rebuild, or a Sparkle
    /// update) leaves launchd holding a job that names the *old* binary. It refuses to
    /// start it, `SMAppService.status` still says `enabled`, and an XPC call then
    /// neither replies nor errors — it simply hangs until the timeout, so a UI toggle
    /// spins for a minute and then silently falls back to the password prompt.
    /// Measured after one rebuild, and it would recur on **every** shipped update.
    ///
    /// `register()` on an already-approved service is idempotent and prompt-free, and
    /// it re-points the job at the current bundle — so the repair is: ping, and if
    /// nothing comes back, re-register and ping once more.
    public static func ensureReady() -> Bool {
        guard state() == .enabled else { return false }
        switch reachability.withLock({ $0 }) {
        case .reachable: return true
        case .unreachable: return false
        case .unknown: break
        }
        if ping() {
            reachability.withLock { $0 = .reachable }
            lastFailureReason = nil
            return true
        }
        let firstFailure = lastFailureReason
        // A plain re-register only. **Never unregister here**: this runs inside an
        // ordinary system-proxy toggle, and an unregister that isn't followed by a
        // successful register leaves the helper *less* installed than it was — the
        // human's approval spent for nothing. Learned the hard way: the destructive
        // version of this line turned a helper that merely wasn't answering into one
        // that was gone. Dropping the record is a repair, and a repair is something
        // the human asks for (the console row), never something a toggle does behind
        // their back.
        try? service.register()
        let repaired = ping()
        reachability.withLock { $0 = repaired ? .reachable : .unreachable }
        if repaired {
            lastFailureReason = nil
        } else if lastFailureReason == nil {
            lastFailureReason = firstFailure
        }
        return repaired
    }

    /// A liveness probe with a **short** timeout. The real operations get a long one
    /// (they run `networksetup` over every service and reload pf); finding out whether
    /// anyone is home must not.
    private static func ping() -> Bool {
        let version = Lock<Int?>(nil)
        let outcome = call(timeout: pingTimeout) { helper, reply in
            helper.helperVersion { value in
                version.withLock { $0 = value }
                reply(true, nil)
            }
        }
        let reported = version.withLock { $0 }
        if reported == HelperConstants.interfaceVersion { return true }
        // A version mismatch means an app talking to a daemon from another build —
        // treat it as unreachable so the caller takes the path that still works, and
        // say which of the two it was.
        lastFailureReason = if let reported {
            "the helper speaks interface v\(reported), this app speaks v\(HelperConstants.interfaceVersion)"
        } else {
            outcome.message ?? "the helper did not answer"
        }
        return false
    }

    /// Rebuild the registration from scratch — **only ever from an explicit human
    /// action** (the console row), because it can spend their approval.
    ///
    /// A plain `register()` is not always enough.
    ///
    /// Apple's advice after replacing an app is to register again, and for a changed
    /// *binary* that works. It does not fix a **dangling bundle reference**: delete the
    /// app bundle and rebuild it at the same path (a `rm -rf DerivedData` — or any
    /// installer that replaces rather than updates in place) and launchd keeps
    /// resolving the old one, logging `Could not find and/or execute program specified
    /// by service: 3: No such process: Contents/MacOS/loom-helper` on a ten-second
    /// respawn loop while `SMAppService.status` reports `enabled` and `register()`
    /// reports success. Measured: 297 failed spawns before it was caught.
    ///
    /// Unregistering first drops the stale record so the new one is built from the
    /// current bundle. The cost is that this can send the service back to
    /// `requiresApproval` — which is why it is a repair, not something done on a hunch:
    /// the caller surfaces the resulting state, and the human may have to allow it
    /// again in Login Items.
    private static func repairRegistration() {
        do {
            try service.unregister()
        } catch {
            // Non-fatal: an unregister failure just means there was nothing to drop.
            lastFailureReason = "unregistering the stale helper failed: \((error as NSError).localizedDescription)"
        }
        // `unregister()` returns before the record is actually gone. Registering into
        // that window loses the race — measured: the new registration landed first and
        // the pending removal then took it away again, leaving BTM at
        // `[disabled, allowed]`, i.e. worse than before (unregistered, but the human's
        // approval spent). Wait for the removal to be visible, briefly and boundedly.
        for _ in 0 ..< 20 {
            if service.status == .notRegistered { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        do {
            try service.register()
        } catch {
            // `register()` throws while succeeding when approval is pending, so the
            // status — not the throw — decides. Only record it if we end up nowhere.
            if state() == .notInstalled {
                lastFailureReason = "re-registering the helper failed: \((error as NSError).localizedDescription)"
            }
        }
    }

    /// Liveness probes get a short deadline; the real operations get `call`'s default,
    /// because they run `networksetup` over every network service and reload pf.
    /// Measured for context: launchd spawns this daemon in ~0.1 s on the first
    /// connection, so seconds here are already generous.
    private static let pingTimeout: TimeInterval = 5

    /// Register the daemon. Returns the state afterwards.
    ///
    /// `register()` throwing is **not** the same as failing: on a first install it
    /// throws "Operation not permitted" while simultaneously moving the service to
    /// `requiresApproval` — the registration landed and macOS is waiting on the
    /// human. So the status after the call is what decides, not the throw. (Reading
    /// the throw as a failure is what makes this feature look impossible on an
    /// ad-hoc build; it registers and loads fine — measured.)
    public static func install() -> (state: HelperState, error: String?) {
        // Both lifecycle calls invalidate what we know about reachability: this one
        // may have just repaired it, the other one just removed it.
        reachability.withLock { $0 = .unknown }
        lastFailureReason = nil
        // Already registered means this tap is a *repair* (the row only offers it when
        // the helper is unresponsive), and a repair has to drop the stale record —
        // registering over it is what silently does nothing.
        if service.status != .notRegistered {
            repairRegistration()
            let after = state()
            return (after, after == .notInstalled ? lastFailureReason : nil)
        }
        do {
            try service.register()
            return (state(), nil)
        } catch {
            let after = state()
            if after == .requiresApproval || after == .enabled { return (after, nil) }
            return (after, (error as NSError).localizedDescription)
        }
    }

    public static func uninstall() -> (state: HelperState, error: String?) {
        reachability.withLock { $0 = .unknown }
        do {
            try service.unregister()
            return (state(), nil)
        } catch {
            return (state(), (error as NSError).localizedDescription)
        }
    }

    /// Open the pane holding the approval switch. There is no API to flip it —
    /// only the human can — so the least we can do is not make them find it.
    public static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// One call over XPC, synchronous from the caller's point of view.
    ///
    /// A fresh connection per call: these are human-speed, one-shot operations, and
    /// a cached connection would have to be re-established after every daemon
    /// restart anyway. `withReply` handlers are guaranteed exactly one resume — the
    /// error handlers below fire only when the reply never will.
    static func call(
        timeout: TimeInterval = 60,
        _ body: @escaping (LoomHelperProtocol, @escaping (Bool, String?) -> Void) -> Void
    ) -> (ok: Bool, message: String?) {
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: LoomHelperProtocol.self)
        // Verify the *daemon* too, by the same rule it verifies us: a mach service
        // is only as trustworthy as what registered it, and checking one direction
        // while assuming the other is how impersonation gets in.
        connection.setCodeSigningRequirement(
            HelperRequirement.forDaemon(teamIdentifier: HelperRequirement.selfTeamIdentifier())
        )
        connection.resume()
        defer { connection.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        // One guarded value, not two: "who finished first" and "with what" have to be
        // decided in the same critical section, or two racers can both see themselves
        // as first. Three things can finish this call — the reply, the connection's
        // error handler, and the timeout below — and exactly one must win.
        let state = Lock(Outcome())
        func finish(_ ok: Bool, _ message: String?) {
            let won = state.withLock { outcome -> Bool in
                guard !outcome.finished else { return false }
                outcome = Outcome(finished: true, ok: ok, message: message)
                return true
            }
            if won { semaphore.signal() }
        }

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            finish(false, "The helper is not reachable: \((error as NSError).localizedDescription)")
        }
        guard let helper = proxy as? LoomHelperProtocol else {
            return (false, "The helper interface did not match.")
        }
        body(helper) { ok, message in finish(ok, message) }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            finish(false, "The helper timed out after \(Int(timeout))s.")
        }
        return state.withLock { ($0.ok, $0.message) }
    }

    private struct Outcome: Sendable {
        var finished = false
        var ok = false
        var message: String? = "The helper did not answer."
    }
}

/// Mutual exclusion for the three-way race above.
///
/// The wrapper is not ceremony: `Synchronization.Mutex` is `~Copyable`, and a
/// noncopyable value **cannot be captured by an escaping closure** — which is
/// exactly what XPC's reply and error handlers are. A final class holding one is
/// capturable and still conforms to **plain** `Sendable`, so the house rule
/// (ProxyCore/CLAUDE.md § Sendable escape hatches: no `@unchecked`, no bare
/// `NSLock`) is kept rather than waived. The alternative — a mutable local `var`
/// captured by those closures — is what actually needs justifying, and it has
/// none: three producers write it from two threads.
private final class Lock<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    func withLock<Result>(_ body: (inout sending Value) -> sending Result) -> sending Result {
        mutex.withLock(body)
    }
}
