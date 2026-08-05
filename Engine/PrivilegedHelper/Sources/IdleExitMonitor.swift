import Foundation
import LoomHelperProtocol
import os

/// Exits the on-demand daemon after a spell of no XPC activity, so a root process
/// isn't resident forever. launchd relaunches it on the next connection. Exit is
/// deferred while a proxy override is still active (something depends on us).
enum IdleExitMonitor {
    private static let logger = Logger(subsystem: HelperIdentity.logSubsystem, category: "IdleExit")
    private static let timeout: TimeInterval = 5 * 60
    private static let queue = DispatchQueue(label: "com.loom.helper.idle")
    /// `nonisolated(unsafe)`: touched only from `queue` — `start`/`noteActivity`
    /// dispatch onto it, and the timer's own event handler runs on it — so the serial
    /// queue is the isolation. Any new access must be dispatched there too.
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?

    static func start() { queue.async { schedule() } }

    static func noteActivity() { queue.async { schedule() } }

    private static func schedule() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + timeout)
        t.setEventHandler { checkAndExit() }
        timer = t
        t.resume()
    }

    private static func checkAndExit() {
        if HelperService.shared.hasActiveOverride {
            logger.info("idle but proxy still overridden — deferring exit")
            schedule()
            return
        }
        logger.info("idle with no override — exiting")
        exit(0)
    }
}
