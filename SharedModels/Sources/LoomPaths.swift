import Foundation

/// The single source of truth for Loom's on-disk locations. Every module that
/// touches `~/Library/Application Support/com.loom/...` resolves it here, so the
/// directory name lives in exactly one place (the app writes the MCP handshake,
/// the `loom-mcp` bridge reads it, and the engine persists the CA / rules / flows
/// alongside — they must all agree).
public enum LoomPaths {
    /// The Application Support subdirectory name. Also the app's bundle prefix.
    public static let directoryName = "com.loom"

    /// `~/Library/Application Support/com.loom`.
    public static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// A file inside the app-support directory.
    public static func appSupportFile(_ name: String) -> URL {
        appSupportDirectory.appendingPathComponent(name)
    }

    /// Create a directory only this user can enter (`0700`).
    ///
    /// Everything Loom keeps here is sensitive: the CA private key, and — just as
    /// much — captured request/response bodies and the audit trail's tool
    /// arguments, which routinely hold passwords and session tokens. The directory
    /// mode is the load-bearing protection, because it covers files Loom doesn't
    /// create itself (SQLite's `-wal` and `-shm` siblings) and files created later.
    public static func createSecureDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // `createDirectory` only applies attributes to directories it creates, so an
        // existing one (from a build before this rule existed) keeps its old mode.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Restrict an existing file to owner-only (`0600`). Best-effort: a missing
    /// file is not an error, since some callers chmod siblings that may not exist
    /// yet.
    public static func restrictToOwner(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// `~/Library/Caches/com.loom` — for regenerable data (favicons, etc.),
    /// distinct from Application Support which holds durable state. `nil` only if
    /// the Caches URL can't be resolved.
    public static var cachesDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(directoryName, isDirectory: true)
    }
}
