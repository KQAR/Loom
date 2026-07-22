import Foundation

/// Loom's Application Support subdirectory. The app writes the handshake here
/// and the `loom-mcp` bridge reads it, so both must agree on this name.
public let loomAppSupportDirectoryName = "com.loom"

public struct MCPHandshake: Codable, Sendable {
    public let token: String
    public let port: Int

    public init(token: String, port: Int) {
        self.token = token
        self.port = port
    }
}

public enum HandshakeStore {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(loomAppSupportDirectoryName, isDirectory: true)
    }

    public static var fileURL: URL {
        directory.appendingPathComponent("mcp-handshake.json")
    }

    /// Persist token+port with owner-only permissions so other users on the
    /// machine can't read the local MCP credential.
    public static func write(_ handshake: MCPHandshake) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(handshake)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public static func read() throws -> MCPHandshake {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(MCPHandshake.self, from: data)
    }
}
