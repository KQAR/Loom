import Foundation
import SharedModels
import os

/// A short-lived child process the helper spawns while a proxy override is active.
/// It polls the owning app; if the app dies (and the proxy is still ours) it
/// restores the backup, so connectivity survives a crash even before the helper's
/// next launch. It exits once the backup is gone (normal restore) or after fixing up.
enum ProxyWatchdog {
    private static let logger = Logger(subsystem: HelperIdentity.logSubsystem, category: "Watchdog")
    static let flag = "--loom-proxy-watchdog"

    /// Returns true if the process was launched in watchdog mode (and has run).
    static func runIfRequested(_ arguments: [String]) -> Bool {
        guard arguments.count >= 3, arguments[1] == flag, let ownerPID = Int32(arguments[2]) else {
            return false
        }
        loop(ownerPID: ownerPID)
        return true
    }

    /// Spawn a detached watchdog for the given owner using our own binary path.
    static func spawn(ownerPID: Int32) {
        guard let selfPath = ProcessInfo.processInfo.arguments.first else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: selfPath)
        process.arguments = [flag, String(ownerPID)]
        try? process.run() // detached; we do not wait
    }

    private static func loop(ownerPID: Int32) {
        while true {
            guard let backup = ProxyBackupStore.read() else { return } // restored elsewhere
            if isProcessAlive(ownerPID) {
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            let stillOurs = backup.services.contains {
                ProxyConfigurator.captureState(of: $0.service).pointsAtLoom(port: backup.loomPort)
            }
            if stillOurs {
                logger.warning("owner pid \(ownerPID) gone — restoring proxy")
                try? ProxyConfigurator.restore(backup.services)
            }
            ProxyBackupStore.clear()
            return
        }
    }
}
