import Foundation
import SharedModels
import SQLite3

/// SQLite-backed durable store for completed flows, so captures survive a
/// relaunch. One table: indexed columns for cheap recency queries plus the whole
/// `Flow` as a JSON blob (leans on Flow's Codable rather than a relational
/// schema). Only completed flows are written — in-flight ones live in the ring —
/// so streaming/WebSocket exchanges cause one write at the end, not per chunk.
///
/// Uses the system `SQLite3` module (no external dependency), serialized behind a
/// private queue since the C handle isn't concurrency-safe.
final class FlowPersistence: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.loom.flowstore.db")
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// Cap rows so the file can't grow forever; pruned oldest-first on write.
    private let maxRows: Int

    // SQLite wants to copy bound bytes, not borrow them.
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(fileURL: URL, maxRows: Int = 20_000) {
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
        CREATE TABLE IF NOT EXISTS flows (
            id TEXT PRIMARY KEY, startedAt REAL, host TEXT, method TEXT, status INTEGER, json BLOB
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS flows_startedAt ON flows(startedAt);")
    }

    deinit { sqlite3_close(db) }

    static func makeDefault() -> FlowPersistence? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let url = base
            .appendingPathComponent("com.loom", isDirectory: true)
            .appendingPathComponent("flows.sqlite")
        return FlowPersistence(fileURL: url)
    }

    func save(_ flow: Flow) {
        guard let data = try? encoder.encode(flow) else { return }
        queue.async { [weak self] in self?.writeRow(flow, data) }
    }

    /// Newest-first, like `FlowStore.recent`.
    func recent(limit: Int) -> [Flow] {
        queue.sync {
            var flows: [Flow] = []
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT json FROM flows ORDER BY startedAt DESC LIMIT ?;", -1, &stmt, nil) == SQLITE_OK
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(max(0, limit)))
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
                let count = Int(sqlite3_column_bytes(stmt, 0))
                let data = Data(bytes: blob, count: count)
                if let flow = try? decoder.decode(Flow.self, from: data) { flows.append(flow) }
            }
            return flows
        }
    }

    func deleteAll() {
        queue.async { [weak self] in self?.exec("DELETE FROM flows;") }
    }

    // MARK: - Private (queue-confined)

    private func writeRow(_ flow: Flow, _ data: Data) {
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO flows (id, startedAt, host, method, status, json) VALUES (?, ?, ?, ?, ?, ?);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, flow.id.uuidString, -1, transient)
        sqlite3_bind_double(stmt, 2, flow.startedAt.timeIntervalSince1970)
        if let host = flow.host { sqlite3_bind_text(stmt, 3, host, -1, transient) } else { sqlite3_bind_null(stmt, 3) }
        sqlite3_bind_text(stmt, 4, flow.request.method, -1, transient)
        if let status = flow.statusCode { sqlite3_bind_int(stmt, 5, Int32(status)) } else { sqlite3_bind_null(stmt, 5) }
        data.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, 6, raw.baseAddress, Int32(data.count), transient)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { return }
        pruneIfNeeded()
    }

    /// Keep at most `maxRows`, dropping the oldest. Cheap: only deletes when over.
    private func pruneIfNeeded() {
        exec("""
        DELETE FROM flows WHERE id IN (
            SELECT id FROM flows ORDER BY startedAt DESC LIMIT -1 OFFSET \(maxRows)
        );
        """)
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}
