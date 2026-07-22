import Foundation
import SharedModels
import os

/// Accepts only XPC connections that pass caller validation, then wires the
/// exported `HelperService`.
final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    private let logger = Logger(subsystem: HelperIdentity.logSubsystem, category: "HelperDelegate")

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard ConnectionValidator.isTrustedCaller(connection) else {
            logger.warning("rejected untrusted caller pid \(connection.processIdentifier)")
            return false
        }
        IdleExitMonitor.noteActivity()
        connection.exportedInterface = NSXPCInterface(with: LoomPrivilegedHelperProtocol.self)
        connection.exportedObject = HelperService.shared
        connection.resume()
        logger.info("accepted caller pid \(connection.processIdentifier)")
        return true
    }
}
