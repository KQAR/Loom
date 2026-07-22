import Foundation
import SharedModels

/// Absolute paths and a validated subprocess runner shared across the helper.
enum HelperPaths {
    static let networkSetup = "/usr/sbin/networksetup"
    static let security = "/usr/bin/security"
    static let systemKeychain = "/Library/Keychains/System.keychain"

    /// Root-owned working directory for the proxy backup the watchdog restores from.
    static let supportDir = "/Library/Application Support/com.loom"
    static let proxyBackup = supportDir + "/proxy-backup.plist"
}

struct CommandResult {
    let code: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { code == 0 }
    var output: String { stderr.isEmpty ? stdout : stderr }
}

enum ProcessRunner {
    enum RunError: Error { case untrustedBinary(String) }

    /// Run an Apple-signed system binary with arguments, capturing output. Refuses
    /// to exec anything that fails code-signature validation (root safety).
    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) throws -> CommandResult {
        guard BinaryValidator.isAppleSigned(at: launchPath) else {
            throw RunError.untrustedBinary(launchPath)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(code: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

enum ProxyBackupStore {
    static func write(_ backup: ProxyBackup) throws {
        try FileManager.default.createDirectory(atPath: HelperPaths.supportDir, withIntermediateDirectories: true)
        let data = try PropertyListEncoder().encode(backup)
        try data.write(to: URL(fileURLWithPath: HelperPaths.proxyBackup), options: .atomic)
    }

    static func read() -> ProxyBackup? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: HelperPaths.proxyBackup)) else { return nil }
        return try? PropertyListDecoder().decode(ProxyBackup.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: HelperPaths.proxyBackup)
    }
}

/// POSIX liveness check that treats EPERM (exists but not ours) as alive.
func isProcessAlive(_ pid: Int32) -> Bool {
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}
