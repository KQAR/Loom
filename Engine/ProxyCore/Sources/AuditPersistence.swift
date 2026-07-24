import Foundation
import LoomSharedModels
import SQLite3

/// SQLite-backed durable store for the write-action audit log, so the trail of
/// what the agent did survives a relaunch. One table, one row per write tool
/// call. Mirrors `FlowPersistence`'s shape: system `SQLite3` (no external dep),
/// serialized behind a private queue since the C handle isn't concurrency-safe,
/// row-capped so the file can't grow forever.
final class AuditPersistence: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.loom.auditstore.db")
    private var db: OpaquePointer?
    /// Cap rows so the file can't grow forever; pruned oldest-first on write.
    private let maxRows: Int

    // SQLite wants to copy bound bytes, not borrow them.
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(fileURL: URL, maxRows: Int = 10_000) {
        self.maxRows = maxRows
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        guard sqlite3_open(fileURL.path, &handle) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        db = handle
        exec("PRAGMA journal_mode=WAL;")
        exec("""
        CREATE TABLE IF NOT EXISTS audit (
            id TEXT PRIMARY KEY, ts REAL, tool TEXT, source TEXT,
            succeeded INTEGER, args TEXT, detail TEXT
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS audit_ts ON audit(ts);")
    }

    deinit { sqlite3_close(db) }

    static func makeDefault() -> AuditPersistence? {
        AuditPersistence(fileURL: LoomPaths.appSupportFile("audit.sqlite"), maxRows: 3000)
    }

    /// Fire-and-forget write; drained by `flush()` on quit.
    func save(_ entry: AuditEntry) {
        queue.async { [weak self] in self?.writeRow(entry) }
    }

    /// Newest-first, like `AuditStore.recent`.
    func recent(limit: Int) -> [AuditEntry] {
        queue.sync {
            var entries: [AuditEntry] = []
            var stmt: OpaquePointer?
            let sql = "SELECT id, ts, tool, source, succeeded, args, detail FROM audit ORDER BY ts DESC LIMIT ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(max(0, limit)))
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let entry = Self.decodeRow(stmt) else { continue }
                entries.append(entry)
            }
            return entries
        }
    }

    func deleteAll() {
        queue.async { [weak self] in self?.exec("DELETE FROM audit;") }
    }

    /// Block until every queued `save`/`deleteAll` has run — call from the quit
    /// handler so the last few writes reach disk. A no-op barrier suffices since
    /// the queue is serial.
    func flush() {
        queue.sync {}
    }

    // MARK: - Private (queue-confined)

    private static func decodeRow(_ stmt: OpaquePointer?) -> AuditEntry? {
        func text(_ column: Int32) -> String {
            sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
        }
        guard let id = UUID(uuidString: text(0)) else { return nil }
        let ts = sqlite3_column_double(stmt, 1)
        let source = AuditEntry.Source(rawValue: text(3)) ?? .mcp
        return AuditEntry(
            id: id,
            timestamp: Date(timeIntervalSince1970: ts),
            tool: text(2),
            source: source,
            succeeded: sqlite3_column_int(stmt, 4) != 0,
            arguments: text(5),
            detail: text(6)
        )
    }

    private func writeRow(_ entry: AuditEntry) {
        var stmt: OpaquePointer?
        let sql = """
        INSERT OR REPLACE INTO audit (id, ts, tool, source, succeeded, args, detail)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, entry.id.uuidString, -1, transient)
        sqlite3_bind_double(stmt, 2, entry.timestamp.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 3, entry.tool, -1, transient)
        sqlite3_bind_text(stmt, 4, entry.source.rawValue, -1, transient)
        sqlite3_bind_int(stmt, 5, entry.succeeded ? 1 : 0)
        sqlite3_bind_text(stmt, 6, entry.arguments, -1, transient)
        sqlite3_bind_text(stmt, 7, entry.detail, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return }
        pruneIfNeeded()
    }

    /// Keep at most `maxRows`, dropping the oldest. Cheap: only deletes when over.
    private func pruneIfNeeded() {
        exec("""
        DELETE FROM audit WHERE id IN (
            SELECT id FROM audit ORDER BY ts DESC LIMIT -1 OFFSET \(maxRows)
        );
        """)
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}
