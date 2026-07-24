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
            id TEXT PRIMARY KEY, startedAt REAL, host TEXT, method TEXT, status INTEGER,
            json BLOB, reqBody BLOB, respBody BLOB
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS flows_startedAt ON flows(startedAt);")
        // Migrate a pre-Layer-1 table (bodies inline in `json`) forward without
        // dropping captures: add the body columns if missing. Legacy rows keep
        // their body-ful `json` and null body columns, which stays correct —
        // `recent` decodes whatever the row's json holds, and hydration only
        // overrides when a body column is present.
        migrateAddBodyColumns()
    }

    /// Add `reqBody`/`respBody` to an old table that predates body separation.
    private func migrateAddBodyColumns() {
        var existing = Set<String>()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(flows);", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1) { existing.insert(String(cString: name)) }
            }
        }
        sqlite3_finalize(stmt)
        if !existing.contains("reqBody") { exec("ALTER TABLE flows ADD COLUMN reqBody BLOB;") }
        if !existing.contains("respBody") { exec("ALTER TABLE flows ADD COLUMN respBody BLOB;") }
    }

    deinit { sqlite3_close(db) }

    static func makeDefault() -> FlowPersistence? {
        FlowPersistence(fileURL: LoomPaths.appSupportFile("flows.sqlite"))
    }

    func save(_ flow: Flow) {
        // Metadata JSON is body-free; the bodies ride in their own BLOB columns so
        // list/boot reads never pay to decode (or base64-inflate) megabyte bodies.
        guard let data = try? encoder.encode(flow.strippingBodies()) else { return }
        let requestBody = flow.request.body
        let responseBody = flow.response?.body
        queue.async { [weak self] in self?.writeRow(flow, data, requestBody, responseBody) }
    }

    /// Newest-first, like `FlowStore.recent`. Body-free: the JSON metadata blob no
    /// longer carries bodies (see `save`), so callers needing a body hydrate it via
    /// `bodies(id:)`. Legacy rows whose json predates separation still return their
    /// inline bodies.
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

    /// The stored request/response bodies for one flow, or nil if the row is gone.
    /// Each side is nil when that body was empty. Legacy rows (bodies still inline
    /// in `json`) return nil columns — the caller's in-memory copy already has them.
    func bodies(id: UUID) -> (request: Data?, response: Data?)? {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT reqBody, respBody FROM flows WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id.uuidString, -1, transient)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            func blob(_ column: Int32) -> Data? {
                guard let raw = sqlite3_column_blob(stmt, column) else { return nil }
                let count = Int(sqlite3_column_bytes(stmt, column))
                return count > 0 ? Data(bytes: raw, count: count) : nil
            }
            return (blob(0), blob(1))
        }
    }

    func deleteAll() {
        queue.async { [weak self] in self?.exec("DELETE FROM flows;") }
    }

    /// Block until every queued `save`/`deleteAll` has run. `save` is fire-and-
    /// forget (`queue.async`), so on quit the last few writes may still be sitting
    /// in the queue — call this from the terminate handler to drain them before
    /// the process dies. A no-op barrier is enough since the queue is serial.
    func flush() {
        queue.sync {}
    }

    // MARK: - Private (queue-confined)

    private func writeRow(_ flow: Flow, _ data: Data, _ requestBody: Data?, _ responseBody: Data?) {
        var stmt: OpaquePointer?
        let sql = """
        INSERT OR REPLACE INTO flows (id, startedAt, host, method, status, json, reqBody, respBody)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
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
        bindBlob(stmt, 7, requestBody)
        bindBlob(stmt, 8, responseBody)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return }
        pruneIfNeeded()
    }

    /// Bind an optional body blob, or NULL when empty. An empty `Data` binds NULL
    /// too, so a body-less flow round-trips as nil rather than a zero-length blob.
    private func bindBlob(_ stmt: OpaquePointer?, _ index: Int32, _ body: Data?) {
        guard let body, !body.isEmpty else { sqlite3_bind_null(stmt, index); return }
        body.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(body.count), transient)
        }
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
