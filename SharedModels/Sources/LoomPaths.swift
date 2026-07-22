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

    /// `~/Library/Caches/com.loom` — for regenerable data (favicons, etc.),
    /// distinct from Application Support which holds durable state. `nil` only if
    /// the Caches URL can't be resolved.
    public static var cachesDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(directoryName, isDirectory: true)
    }
}
