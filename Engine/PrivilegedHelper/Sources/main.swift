import Foundation
import SharedModels
import os

// Loom privileged helper (root daemon, M2 — UNVERIFIED SCAFFOLD).
//
// Registered via SMAppService, this performs the operations the sandboxed app
// cannot: pointing the system proxy at Loom and trusting Loom's root CA in the
// system keychain. Hardening: caller code-signature validation, Apple-signed
// binary checks before exec, precise per-service proxy backup/restore, a crash
// watchdog, and idle self-exit. Compiles, but end-to-end operation needs a
// signed/notarized app with the helper embedded — not exercised in CI.

// Watchdog mode: spawned as a child while an override is active; restores the
// proxy if the owning app dies, then exits.
if ProxyWatchdog.runIfRequested(ProcessInfo.processInfo.arguments) {
    exit(0)
}

let logger = Logger(subsystem: HelperIdentity.logSubsystem, category: "Main")
logger.info("LoomHelper starting")

// Undo any override left by a previous crash before serving requests.
CrashRecovery.restoreIfNeeded()

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: HelperIdentity.machServiceName)
listener.delegate = delegate
listener.resume()
logger.info("listening on \(HelperIdentity.machServiceName, privacy: .public)")

IdleExitMonitor.start()
RunLoop.current.run()
