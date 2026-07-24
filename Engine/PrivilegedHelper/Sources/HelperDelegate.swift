import Foundation
import LoomSharedModels
import os

/// Accepts only XPC connections that pass caller validation, then wires the
/// exported `HelperService`.
final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    private let logger = Logger(subsystem: HelperIdentity.logSubsystem, category: "HelperDelegate")

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Enforce the caller's code-signing requirement via the OS (macOS 13+),
        // which validates the peer's audit token internally — no PID-reuse window
        // and no private-API KVC audit-token hack. A caller that doesn't satisfy
        // the requirement gets its connection invalidated by XPC.
        connection.setCodeSigningRequirement(HelperIdentity.callerCodeRequirement)
        IdleExitMonitor.noteActivity()
        connection.exportedInterface = NSXPCInterface(with: LoomPrivilegedHelperProtocol.self)
        connection.exportedObject = HelperService.shared
        connection.resume()
        logger.info("accepted caller pid \(connection.processIdentifier)")
        return true
    }
}
