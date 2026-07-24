import Foundation

/// One record in the write-action audit log: a single MCP write tool call the
/// agent made, with its arguments and outcome. The audit log exists so the
/// supervising human (and a later agent) can see *what the AI did* to real
/// traffic — the flip side of Loom's differentiator, which is that the MCP
/// surface exposes write actions at all (replay / rules / breakpoints /
/// ssl-scope), not just reads. Read tools are never logged; only writes.
///
/// Stored durably (SQLite) so the trail survives a relaunch, bounded like the
/// flow ring so it can't grow forever.
public struct AuditEntry: Equatable, Codable, Sendable, Identifiable {
    /// Who initiated the write. Today only the MCP surface is logged (the agent);
    /// `ui` is reserved so human-initiated writes can fold in later without a
    /// schema change.
    public enum Source: String, Codable, Sendable {
        case mcp
        case ui
    }

    public let id: UUID
    public let timestamp: Date
    /// The MCP tool name, e.g. `replay_flow`, `create_rule`.
    public let tool: String
    public let source: Source
    /// Whether the action succeeded. A failure still logs — "the agent tried to
    /// X and it failed" is exactly what a supervisor needs to see.
    public let succeeded: Bool
    /// The arguments the caller passed, as compact JSON (truncated; see
    /// `AuditEntry.cap`). What the agent asked for.
    public let arguments: String
    /// A short summary of the result on success, or the error message on failure.
    public let detail: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        tool: String,
        source: Source = .mcp,
        succeeded: Bool,
        arguments: String,
        detail: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.tool = tool
        self.source = source
        self.succeeded = succeeded
        self.arguments = arguments
        self.detail = detail
    }

    /// Max characters retained for `arguments` / `detail`. An audit entry records
    /// *that* and *roughly what*, not a full payload copy — a multi-megabyte
    /// base64 mock body or replay result would bloat the log for no audit value.
    public static let cap = 2000

    /// Truncate a rendered field to `cap`, marking that it was cut so a reader
    /// never mistakes a clipped value for the whole thing.
    public static func truncate(_ text: String, cap: Int = cap) -> String {
        guard text.count > cap else { return text }
        return String(text.prefix(cap)) + "… (\(text.count - cap) more chars)"
    }
}
