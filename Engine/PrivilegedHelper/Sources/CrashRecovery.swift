import Foundation
import SharedModels
import os

/// On helper startup, undo a proxy override left behind by an app (or helper)
/// that died before restoring. Without this, a crash leaves the system proxy
/// pointing at a dead port and the machine loses connectivity.
enum CrashRecovery {
    private static let logger = Logger(subsystem: HelperIdentity.logSubsystem, category: "CrashRecovery")

    static func restoreIfNeeded() {
        guard let backup = ProxyBackupStore.read() else { return }

        // If the owning app is still alive, it's responsible for restoring.
        if isProcessAlive(backup.ownerPID) {
            logger.info("backup owner pid \(backup.ownerPID) alive — leaving proxy as is")
            return
        }
        // Only restore if the proxy still looks like ours; otherwise the user (or
        // another tool) has since changed it and we must not clobber that.
        let stillOurs = backup.services.contains { ProxyConfigurator.captureState(of: $0.service).pointsAtLoom(port: backup.loomPort) }
        guard stillOurs else {
            logger.info("proxy no longer points at Loom — discarding stale backup")
            ProxyBackupStore.clear()
            return
        }
        logger.warning("restoring proxy after owner pid \(backup.ownerPID) exit")
        do {
            try ProxyConfigurator.restore(backup.services)
            ProxyBackupStore.clear()
        } catch {
            logger.error("crash restore failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
