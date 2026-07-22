import Foundation
import SharedModels
import os

/// The object exported over XPC. Implements the privileged operations and owns
/// the override lifecycle (backup on override, spawn the watchdog, restore on
/// request/uninstall). Thread-safe: XPC delivers calls concurrently.
final class HelperService: NSObject, LoomPrivilegedHelperProtocol {
    static let shared = HelperService()

    private let logger = Logger(subsystem: HelperIdentity.logSubsystem, category: "HelperService")
    private let lock = NSLock()
    private var activePort: Int?

    var hasActiveOverride: Bool {
        lock.lock(); defer { lock.unlock() }
        return activePort != nil
    }

    // MARK: Proxy

    func overrideSystemProxy(port: Int, ownerPID: Int32, withReply reply: @escaping (Bool, String?) -> Void) {
        IdleExitMonitor.noteActivity()
        do {
            let snapshots = try ProxyConfigurator.applyOverride(port: port)
            let backup = ProxyBackup(services: snapshots, ownerPID: ownerPID, loomPort: port, createdAt: Date())
            try ProxyBackupStore.write(backup)
            ProxyWatchdog.spawn(ownerPID: ownerPID)
            lock.lock(); activePort = port; lock.unlock()
            logger.info("system proxy overridden to 127.0.0.1:\(port) for owner \(ownerPID)")
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func restoreSystemProxy(withReply reply: @escaping (Bool, String?) -> Void) {
        IdleExitMonitor.noteActivity()
        guard let backup = ProxyBackupStore.read() else {
            lock.lock(); activePort = nil; lock.unlock()
            reply(true, nil) // nothing to restore
            return
        }
        do {
            try ProxyConfigurator.restore(backup.services)
            ProxyBackupStore.clear()
            lock.lock(); activePort = nil; lock.unlock()
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func getProxyStatus(withReply reply: @escaping (Bool, Int) -> Void) {
        IdleExitMonitor.noteActivity()
        let port = lock.withLock { activePort } ?? (ProxyBackupStore.read()?.loomPort ?? 0)
        let status = ProxyConfigurator.status(loomPort: port)
        reply(status.0, status.1)
    }

    // MARK: Certificate trust

    func installTrustedCertificate(_ der: Data, withReply reply: @escaping (Bool, String?) -> Void) {
        IdleExitMonitor.noteActivity()
        let (ok, message) = CertificateInstaller.install(der: der)
        reply(ok, message)
    }

    func removeTrustedCertificate(_ der: Data, withReply reply: @escaping (Bool, String?) -> Void) {
        IdleExitMonitor.noteActivity()
        let (ok, message) = CertificateInstaller.remove(der: der)
        reply(ok, message)
    }

    func verifyCertificateTrusted(sha256Fingerprint: String, withReply reply: @escaping (Bool) -> Void) {
        IdleExitMonitor.noteActivity()
        reply(CertificateInstaller.isTrusted(sha256Fingerprint: sha256Fingerprint))
    }

    // MARK: Meta

    func getHelperInfo(withReply reply: @escaping (String, Int, Int) -> Void) {
        IdleExitMonitor.noteActivity()
        reply(HelperIdentity.version, HelperIdentity.protocolVersion, HelperIdentity.protocolVersion)
    }

    func prepareForUninstall(withReply reply: @escaping (Bool) -> Void) {
        IdleExitMonitor.noteActivity()
        if let backup = ProxyBackupStore.read() {
            try? ProxyConfigurator.restore(backup.services)
            ProxyBackupStore.clear()
        }
        lock.lock(); activePort = nil; lock.unlock()
        reply(true)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
