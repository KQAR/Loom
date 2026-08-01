import Foundation
import LoomHelperProtocol
import os

// Loom privileged helper (root daemon, M2 — DORMANT BY DECISION, never loaded).
//
// It would register via SMAppService and perform the operations the sandboxed app
// cannot: pointing the system proxy at Loom and trusting Loom's root CA in the
// system keychain. Hardening: caller code-signature validation, Apple-signed
// binary checks before exec, precise per-service proxy backup/restore, a crash
// watchdog, and idle self-exit. It compiles and its pure logic is unit-tested, but
// Loom signs ad-hoc only, so launchd refuses to load it — the app ships
// user-domain CA trust and a direct `networksetup` path instead. Kept as a design
// record; read ROADMAP § M2 before scheduling work here.

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
