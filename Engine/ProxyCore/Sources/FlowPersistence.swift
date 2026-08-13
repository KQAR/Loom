import Foundation
import LoomSharedModels
import SQLite3
import Synchronization

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
    /// Cap rows so the file can't grow forever; pruned oldest-first.
    private let maxRows: Int
    /// Prune only once the cap is exceeded by this much, then re-count exactly.
    /// Pruning per write meant a full index scan (`ORDER BY startedAt` + delete
    /// attempt) for every captured flow. The trade is explicit: the file may hold
    /// up to `maxRows + pruneSlack` rows between prunes (2.5% at the default cap).
    private let pruneSlack: Int
    /// Upper bound on rows, maintained incrementally and re-read exactly after each
    /// prune. `INSERT OR REPLACE` can replace rather than add, so this over-counts
    /// at worst — pruning slightly early is harmless, skipping it would not be.
    ///
    /// Backed by `counts` rather than a plain stored property, so the number is
    /// readable **without hopping this store's queue** — see `approximateStoredRowCount`
    /// for why that matters. Every existing queue-confined read and write of
    /// `rowCount` goes on working unchanged, which is the point: a mirror that a
    /// future write site can forget to update is a mirror that drifts.
    private var rowCount: Int {
        get { counts.withLock { $0.stored } }
        set { counts.withLock { $0.stored = newValue } }
    }

    /// The row count as two halves — written rows and rows still in the batch — held
    /// outside the queue so a reader never has to enter it.
    private let counts = Mutex<Counts>(Counts())

    private struct Counts {
        var stored = 0
        var pending = 0
    }

    /// Call after every mutation of `pending`, so `approximateStoredRowCount` counts
    /// a flow that has been saved but not yet written.
    private func notePendingChanged() {
        let count = pending.count
        counts.withLock { $0.pending = count }
    }

    /// Rows waiting to be written, and the batching window. Each `save` used to be
    /// its own transaction (and its own `sqlite3_prepare_v2`); a capture burst now
    /// costs one transaction per window instead of one per flow. Every read drains
    /// this first, so batching is invisible to callers.
    private var pending: [Row] = []
    private var flushScheduled = false
    private let batchWindow: TimeInterval = 0.05
    private let maxBatch = 256
    /// Reused across writes instead of re-prepared per row.
    private var insertStatement: OpaquePointer?
    /// Called with the flows a prune deleted, on this store's queue.
    ///
    /// The pruner is the only place a *retained* flow disappears without anyone having
    /// asked, so it is the only place an aggregate maintained upstream can silently
    /// drift. A callback rather than a return value because pruning happens inside a
    /// write, not in answer to a caller.
    var onPrune: (@Sendable ([Flow]) -> Void)?

    /// One row's worth of already-encoded values, captured off the queue.
    private struct Row {
        let id: String
        let startedAt: Double
        let host: String?
        let method: String
        let status: Int?
        let json: Data
        let requestBody: Data?
        let responseBody: Data?
        /// The four values `aggregate()` folds, lifted out of the JSON so counting
        /// them is a `GROUP BY` instead of a decode per row — see `aggregate()`.
        let appKey: String?
        let appJSON: Data?
        let deviceKey: String?
        let deviceJSON: Data?
        let isError: Bool
    }

    // SQLite wants to copy bound bytes, not borrow them.
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(fileURL: URL, maxRows: Int = FlowLimits.persistedRows, pruneSlack: Int = 500) {
        self.maxRows = maxRows
        self.pruneSlack = max(0, pruneSlack)
        // Owner-only, like the CA store: these rows hold whole request and response
        // bodies — passwords, session tokens, PII — so on a shared Mac they are a
        // bigger prize than the CA key. The directory mode is what covers SQLite's
        // `-wal`/`-shm` siblings, which Loom never creates itself.
        try? LoomPaths.createSecureDirectory(at: fileURL.deletingLastPathComponent())
        var handle: OpaquePointer?
        guard sqlite3_open(fileURL.path, &handle) == SQLITE_OK else {
            // The caller falls back to a ring-only store: captures then vanish on
            // quit, and nothing else would have said so.
            Log.store.error("""
            Could not open the flow database at \(fileURL.path, privacy: .public) \
            (\(String(cString: sqlite3_errmsg(handle)), privacy: .public)); \
            captured flows will not persist across launches.
            """)
            sqlite3_close(handle)
            return nil
        }
        db = handle
        Self.restrictDatabaseFiles(at: fileURL)
        exec("PRAGMA journal_mode=WAL;")
        // WAL's standard durability setting: writes still survive a process crash;
        // only a power loss can lose the last transactions. FULL fsyncs on every
        // commit, which is a poor trade for captured traffic.
        exec("PRAGMA synchronous=NORMAL;")
        exec("""
        CREATE TABLE IF NOT EXISTS flows (
            id TEXT PRIMARY KEY, startedAt REAL, host TEXT, method TEXT, status INTEGER,
            json BLOB, reqBody BLOB, respBody BLOB,
            appKey TEXT, appJSON BLOB, deviceKey TEXT, deviceJSON BLOB, isError INTEGER
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS flows_startedAt ON flows(startedAt);")
        migrateAddAggregateColumns()
        // Migrate a pre-Layer-1 table (bodies inline in `json`) forward without
        // dropping captures: add the body columns if missing. Legacy rows keep
        // their body-ful `json` and null body columns, which stays correct —
        // `recent` decodes whatever the row's json holds, and hydration only
        // overrides when a body column is present.
        migrateAddBodyColumns()
        rowCount = countRows()
    }

    /// Belt to the directory's braces: chmod the database and its WAL siblings to
    /// `0600`. Best-effort and re-run on every open, because SQLite creates
    /// `-wal`/`-shm` on first write — an install predating this change has them
    /// already, a fresh one grows them under a `0700` directory either way.
    static func restrictDatabaseFiles(at fileURL: URL) {
        for suffix in ["", "-wal", "-shm"] {
            LoomPaths.restrictToOwner(URL(fileURLWithPath: fileURL.path + suffix))
        }
    }

    /// `PRAGMA user_version` once the aggregate columns hold a value for **every**
    /// row. Below it, `appKey`/`deviceKey` being NULL is ambiguous — the row may
    /// predate the columns rather than have had no app — so `aggregate()` must not
    /// trust them. See `backfillAggregateColumns`.
    static let aggregateSchemaVersion: Int32 = 2

    /// Add the four aggregate columns to a table that predates them, and mark a
    /// *fresh* table as already backfilled (there is nothing in it to backfill).
    private func migrateAddAggregateColumns() {
        for column in ["appKey TEXT", "appJSON BLOB", "deviceKey TEXT", "deviceJSON BLOB", "isError INTEGER"]
        where !hasColumn(String(column.prefix(while: { $0 != " " }))) {
            exec("ALTER TABLE flows ADD COLUMN \(column);")
        }
        if userVersion < Self.aggregateSchemaVersion, countRows() == 0 {
            userVersion = Self.aggregateSchemaVersion
        }
    }

    private func hasColumn(_ name: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(flows);", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let column = sqlite3_column_text(stmt, 1), String(cString: column) == name { return true }
        }
        return false
    }

    private var userVersion: Int32 {
        get {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int(stmt, 0)
        }
        set { exec("PRAGMA user_version = \(newValue);") }
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

    deinit {
        // Don't lose a batch that was still inside its window. Called directly, not
        // via `queue.sync`: a queued closure holds a temporary strong reference
        // while it runs, so the last release can happen *on* this queue — and
        // `sync` from the queue it targets deadlocks. `deinit` means no other code
        // can hold a reference, so exclusive access is already guaranteed.
        writePending()
        sqlite3_finalize(insertStatement)
        sqlite3_close(db)
    }

    static func makeDefault() -> FlowPersistence? {
        FlowPersistence(fileURL: LoomPaths.appSupportFile("flows.sqlite"))
    }

    func save(_ flow: Flow) {
        // Metadata JSON is body-free; the bodies ride in their own BLOB columns so
        // list/boot reads never pay to decode (or base64-inflate) megabyte bodies.
        let data: Data
        do {
            data = try encoder.encode(flow.strippingBodies())
        } catch {
            Log.store.error("Encoding flow \(flow.id.uuidString, privacy: .public) failed; it will not persist: \(String(describing: error))")
            return
        }
        let row = Row(
            id: flow.id.uuidString,
            startedAt: flow.startedAt.timeIntervalSince1970,
            host: flow.host,
            method: flow.request.method,
            status: flow.statusCode,
            json: data,
            requestBody: flow.request.body,
            responseBody: flow.response?.body,
            appKey: flow.sourceApp?.groupingKey,
            appJSON: flow.sourceApp.flatMap { try? encoder.encode($0) },
            deviceKey: flow.sourceDevice?.groupingKey,
            deviceJSON: flow.sourceDevice.flatMap { try? encoder.encode($0) },
            isError: FlowAggregates.isError(flow)
        )
        // Strong capture on purpose: a save must not be dropped because the store
        // was released before the queue got to it. This means the last reference can
        // be released *by the queue*, so `deinit` may run on it — which is why
        // `deinit` flushes directly instead of via `queue.sync`.
        queue.async { self.enqueue(row) }
    }

    /// Newest-first, like `FlowStore.recent`. Body-free: the JSON metadata blob no
    /// longer carries bodies (see `save`), so callers needing a body hydrate it via
    /// `bodies(id:)`. Legacy rows whose json predates separation still return their
    /// inline bodies.
    func recent(limit: Int) -> [Flow] {
        queue.sync {
            writePending() // a batched save must be visible to the very next read
            var flows: [Flow] = []
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT json FROM flows ORDER BY startedAt DESC LIMIT ?;", -1, &stmt, nil) == SQLITE_OK
            else {
                Log.store.error("Reading recent flows failed: \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
                return []
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(max(0, limit)))
            var undecodable = 0
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
                let count = Int(sqlite3_column_bytes(stmt, 0))
                let data = Data(bytes: blob, count: count)
                if let flow = try? decoder.decode(Flow.self, from: data) {
                    flows.append(flow)
                } else {
                    undecodable += 1
                }
            }
            if undecodable > 0 {
                // Rows that exist but can't be decoded simply vanish from the list —
                // a capture that looks like it never happened.
                Log.store.error("Skipped \(undecodable) undecodable flow row(s) while reading history.")
            }
            return flows
        }
    }

    /// One flow by id, bodies attached — the read that makes the durable store
    /// reachable, not just writable. The table keeps far more rows than the
    /// in-memory ring, so an id a caller legitimately holds (from an earlier list,
    /// a `replayedFrom` link, an exported HAR) resolves after the flow has aged out.
    /// Nil when there is no such row.
    func flow(id: UUID) -> Flow? {
        queue.sync {
            writePending()
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT json, reqBody, respBody FROM flows WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id.uuidString, -1, transient)
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let blob = sqlite3_column_blob(stmt, 0)
            else { return nil }
            let json = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
            guard let flow = try? decoder.decode(Flow.self, from: json) else { return nil }
            let request = Self.blob(stmt, 1)
            let response = Self.blob(stmt, 2)
            // A legacy row carries its bodies inline in `json` and null columns —
            // leave those alone rather than blanking them.
            guard request != nil || response != nil else { return flow }
            return flow.attachingBodies(request: request, response: response)
        }
    }

    /// Newest-first rows matching `query`, skipping ids the caller already has.
    ///
    /// ## Why this exists
    ///
    /// `FlowStore.recent(matching:)` scanned the **ring only** — 2000 flows — while
    /// this table keeps 20 000. Nine of every ten persisted exchanges could not be
    /// found by any search, and the miss was silent: `get_recent_flows` with a filter
    /// returned `[]` for "not in the last 2000" and for "never happened" alike, which
    /// is the failure `TunneledHostLog` exists to prevent one layer up. `flow(id:)`
    /// and `recentHydrated` already read through; the query path was the one that
    /// didn't, so an id an agent held resolved while a search for the same exchange
    /// came back empty.
    ///
    /// ## Cost, and the ordering that bounds it
    ///
    /// Only `host`/`method`/`status`/`since` map to columns, so those are pushed into
    /// SQL (the `startedAt` index carries the ordering and the `since` bound); the rest
    /// of the predicate runs in Swift against the decoded row. `rowBudget` caps how
    /// many rows are *examined*, so a needle that matches nothing can't turn into an
    /// unbounded walk on the write queue — and the caller is told it was hit, rather
    /// than reading a short result as an exhaustive one.
    ///
    /// A body predicate reads the blob columns, and only for a row that already passed
    /// every cheap predicate — the same ordering `FlowStore.scan` uses, for the same
    /// reason: one blob read per non-match is the cost being avoided.
    ///
    /// A host **glob** is not pushed down (SQL `LIKE` and Loom's glob are not the same
    /// language, and getting that subtly wrong would drop matching rows); it is matched
    /// in Swift like the rest.
    func scan(
        matching query: FlowQuery,
        after cursor: FlowCursor? = nil,
        limit: Int,
        excluding seen: Set<UUID>,
        rowBudget: Int
    ) -> (flows: [Flow], budgetExhausted: Bool) {
        guard limit > 0, rowBudget > 0 else { return ([], false) }
        return queue.sync {
            writePending() // a batched save must be visible to the very next read
            var sql = "SELECT json, reqBody, respBody FROM flows"
            var conditions: [String] = []
            // Keyset seek, in the same order the `ORDER BY` below sorts: strictly older,
            // or the same instant with a lower id. `id` is the uuidString, which is the
            // order `FlowCursor` compares in, so a page boundary means the same thing
            // here as it does in the ring.
            if cursor != nil { conditions.append("(startedAt < ? OR (startedAt = ? AND id < ?))") }
            if let host = query.host, !host.contains("*") { conditions.append("host = ?") }
            if let methods = query.methods, !methods.isEmpty {
                let slots = Array(repeating: "?", count: methods.count).joined(separator: ", ")
                conditions.append("UPPER(method) IN (\(slots))")
            }
            if query.statusMin != nil { conditions.append("status >= ?") }
            if query.statusMax != nil { conditions.append("status <= ?") }
            if query.since != nil { conditions.append("startedAt >= ?") }
            if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
            // `id` breaks the tie, or a page boundary landing between two rows captured
            // in the same millisecond would drop one and repeat the other.
            sql += " ORDER BY startedAt DESC, id DESC LIMIT ?;"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                Log.store.error("Scanning flow history failed: \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
                return ([], false)
            }
            defer { sqlite3_finalize(stmt) }

            var index: Int32 = 1
            func bind(_ body: (Int32) -> Void) { body(index); index += 1 }
            if let cursor {
                bind { sqlite3_bind_double(stmt, $0, cursor.startedAt.timeIntervalSince1970) }
                bind { sqlite3_bind_double(stmt, $0, cursor.startedAt.timeIntervalSince1970) }
                bind { sqlite3_bind_text(stmt, $0, cursor.id.uuidString, -1, transient) }
            }
            if let host = query.host, !host.contains("*") {
                bind { sqlite3_bind_text(stmt, $0, host, -1, transient) }
            }
            for method in query.methods ?? [] {
                bind { sqlite3_bind_text(stmt, $0, method.uppercased(), -1, transient) }
            }
            if let statusMin = query.statusMin { bind { sqlite3_bind_int(stmt, $0, Int32(statusMin)) } }
            if let statusMax = query.statusMax { bind { sqlite3_bind_int(stmt, $0, Int32(statusMax)) } }
            // Unix epoch, matching what `save` binds — a reference-date reading here
            // would be 31 years off and silently filter everything out.
            if let since = query.since {
                bind { sqlite3_bind_double(stmt, $0, since.timeIntervalSince1970) }
            }
            bind { sqlite3_bind_int(stmt, $0, Int32(rowBudget)) }

            // Prepared before the walk, like the ring's scan: this loop decodes rows off
            // disk, and re-preparing the query per row would add to the one cost the row
            // budget exists to bound.
            let predicate = query.metadataPredicate()
            let bodies = query.bodyPredicate()
            var matches: [Flow] = []
            var examined = 0
            while matches.count < limit, sqlite3_step(stmt) == SQLITE_ROW {
                examined += 1
                guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
                let json = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
                guard let flow = try? decoder.decode(Flow.self, from: json), !seen.contains(flow.id)
                else { continue }
                guard predicate.matches(flow) else { continue }
                if query.needsBodies {
                    let hydrated = flow.attachingBodies(
                        request: Self.blob(stmt, 1), response: Self.blob(stmt, 2)
                    )
                    guard bodies.matches(hydrated) else { continue }
                }
                // The body-free row, like every other list read (invariant I2).
                matches.append(flow)
            }
            return (matches, examined >= rowBudget && matches.count < limit)
        }
    }

    /// How many rows the table holds. The denominator behind "searched N of M", and
    /// half of a paged list's row count.
    ///
    /// **The one read that does not enter the queue, and it must stay that way.** Every
    /// other read here opens with `queue.sync { writePending() }`, which is right for
    /// them — they are about to return rows, so a flow saved a few milliseconds ago has
    /// to be on disk first. This one returns a *number*, and paying that price for it
    /// was a stall in exactly the place `FlowStore` documents as forbidden: the callers
    /// (`FlowStore.retainedCount`, `search`, `totalRetained`) are all **on the
    /// `FlowStore` actor**, so `ProxyEngine.status()` held the actor every capture write
    /// queues on while this queue ran a whole 256-row transaction. `status()` is not
    /// rare — the audit fan-out re-reads it after every agent write, the panel reads it
    /// on open, and `get_proxy_status` is a poll an agent is encouraged to make.
    ///
    /// So the count is mirrored out of the queue instead (`counts`), including the rows
    /// still sitting in the batch — which is what draining bought and is preserved here
    /// without the transaction. It is approximate for the reason `rowCount` already was
    /// (an `INSERT OR REPLACE` that replaces still counts as an add until the next
    /// prune re-anchors it), and every caller wants a magnitude: a "of M" denominator, a
    /// "flows retained" figure, a list's total. Anything needing an exact count must ask
    /// for it a way that reads rows.
    var approximateStoredRowCount: Int {
        counts.withLock { $0.stored + $0.pending }
    }

    /// The stored request/response bodies for one flow, or nil if the row is gone.
    /// Each side is nil when that body was empty. Legacy rows (bodies still inline
    /// in `json`) return nil columns — the caller's in-memory copy already has them.
    func bodies(id: UUID) -> (request: Data?, response: Data?)? {
        queue.sync {
            writePending()
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT reqBody, respBody FROM flows WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id.uuidString, -1, transient)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return (Self.blob(stmt, 0), Self.blob(stmt, 1))
        }
    }

    /// A BLOB column as `Data`, or nil when NULL/empty.
    private static func blob(_ stmt: OpaquePointer?, _ column: Int32) -> Data? {
        guard let raw = sqlite3_column_blob(stmt, column) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, column))
        return count > 0 ? Data(bytes: raw, count: count) : nil
    }

    func deleteAll() {
        // Strong, like `save`: a dropped delete would leave rows on disk that the
        // app believes are gone, and they'd reappear on the next launch.
        queue.async {
            self.pending.removeAll() // no point writing rows we're about to delete
            self.notePendingChanged()
            self.exec("DELETE FROM flows;")
            self.rowCount = 0
        }
    }

    /// Block until every queued `save`/`deleteAll` has run *and* any batched rows
    /// have hit the file. `save` is fire-and-forget (`queue.async`) and batched, so
    /// on quit the last few writes may still be queued or inside their window —
    /// call this from the terminate handler before the process dies.
    func flush() {
        queue.sync { writePending() }
    }

    // MARK: - Private (queue-confined)

    /// Queue a row and arrange for the batch to land. A full batch writes
    /// immediately so a sustained capture never buffers more than `maxBatch`.
    private func enqueue(_ row: Row) {
        pending.append(row)
        notePendingChanged()
        if pending.count >= maxBatch {
            writePending()
            return
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + batchWindow) { [weak self] in self?.writePending() }
    }

    /// Write every queued row in one transaction, reusing one prepared statement.
    /// Idempotent and cheap when empty, so reads can call it unconditionally.
    private func writePending() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let rows = pending
        pending.removeAll(keepingCapacity: true)
        notePendingChanged()

        exec("BEGIN IMMEDIATE;")
        var written = 0
        for row in rows where writeRow(row) { written += 1 }
        exec("COMMIT;")

        if written < rows.count {
            // Logged once per batch rather than per row: a failing database would
            // otherwise flood the log at capture rate.
            Log.store.error("""
            \(rows.count - written) of \(rows.count) flows failed to persist \
            (\(String(cString: sqlite3_errmsg(self.db)), privacy: .public)); they remain in \
            memory only and will be lost on quit.
            """)
        }
        rowCount += written
        pruneIfNeeded()
    }

    /// Bind and step one row on the shared statement. Returns whether it landed.
    private func writeRow(_ row: Row) -> Bool {
        guard let stmt = preparedInsert() else { return false }
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        sqlite3_bind_text(stmt, 1, row.id, -1, transient)
        sqlite3_bind_double(stmt, 2, row.startedAt)
        if let host = row.host { sqlite3_bind_text(stmt, 3, host, -1, transient) } else { sqlite3_bind_null(stmt, 3) }
        sqlite3_bind_text(stmt, 4, row.method, -1, transient)
        if let status = row.status { sqlite3_bind_int(stmt, 5, Int32(status)) } else { sqlite3_bind_null(stmt, 5) }
        row.json.withUnsafeBytes { raw in
            // `_ =` on the bind, not on `withUnsafeBytes`: the closure's last
            // expression is otherwise its return value, so the *block* result goes
            // unused and the compiler flags that instead of the thing being ignored.
            // Every other bind here discards its status the same way — imported C
            // functions are implicitly discardable, this one just isn't in tail position.
            _ = sqlite3_bind_blob(stmt, 6, raw.baseAddress, Int32(row.json.count), transient)
        }
        bindBlob(stmt, 7, row.requestBody)
        bindBlob(stmt, 8, row.responseBody)
        if let appKey = row.appKey { sqlite3_bind_text(stmt, 9, appKey, -1, transient) } else { sqlite3_bind_null(stmt, 9) }
        bindBlob(stmt, 10, row.appJSON)
        if let deviceKey = row.deviceKey { sqlite3_bind_text(stmt, 11, deviceKey, -1, transient) } else { sqlite3_bind_null(stmt, 11) }
        bindBlob(stmt, 12, row.deviceJSON)
        sqlite3_bind_int(stmt, 13, row.isError ? 1 : 0)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// The insert statement, prepared once and kept. Re-preparing per row was pure
    /// overhead on the write path.
    private func preparedInsert() -> OpaquePointer? {
        if let insertStatement { return insertStatement }
        let sql = """
        INSERT OR REPLACE INTO flows (id, startedAt, host, method, status, json, reqBody, respBody,
                                      appKey, appJSON, deviceKey, deviceJSON, isError)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        insertStatement = stmt
        return stmt
    }

    /// Bind an optional body blob, or NULL when empty. An empty `Data` binds NULL
    /// too, so a body-less flow round-trips as nil rather than a zero-length blob.
    private func bindBlob(_ stmt: OpaquePointer?, _ index: Int32, _ body: Data?) {
        guard let body, !body.isEmpty else { sqlite3_bind_null(stmt, index); return }
        body.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(body.count), transient)
        }
    }

    /// Keep at most `maxRows`, dropping the oldest — but only once the count has
    /// drifted `pruneSlack` past the cap. This used to run on *every* write: a full
    /// `ORDER BY startedAt` index scan plus a delete attempt per captured flow.
    private func pruneIfNeeded() {
        guard rowCount > maxRows + pruneSlack else { return }
        // Read what is about to go before deleting it. These flows never pass back
        // through `FlowStore.upsert` — the pruner is the one place a retained flow
        // disappears without anyone asking — so the aggregate counts would keep
        // counting them forever, and a host whose every row had been pruned would sit
        // in the sidebar with rows no read can find.
        let doomed = decodeRows(sql: """
        SELECT json FROM flows ORDER BY startedAt DESC LIMIT -1 OFFSET \(maxRows);
        """)
        exec("""
        DELETE FROM flows WHERE id IN (
            SELECT id FROM flows ORDER BY startedAt DESC LIMIT -1 OFFSET \(maxRows)
        );
        """)
        rowCount = countRows() // the estimate was an upper bound; re-anchor it
        if !doomed.isEmpty { onPrune?(doomed) }
    }

    /// Decode the `json` column of every row a statement returns. Shared by the boot
    /// aggregation and the prune notification, which want the same thing.
    private func decodeRows(sql: String) -> [Flow] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var flows: [Flow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
            if let flow = try? decoder.decode(Flow.self, from: data) { flows.append(flow) }
        }
        return flows
    }

    /// Every retained row, folded into counts. Run once at boot, off the actor.
    ///
    /// **A `GROUP BY` over columns, not a decode per row** — that swap is what this
    /// method is about. It used to decode the whole table, on the reasoning that only
    /// `host` was a column while the app, the device and the display representatives
    /// the sidebar needs lived inside the JSON. Measured on a full 20 000-row table:
    /// **293 ms, of which 3.6 ms is SQLite** — the other 290 ms was `JSONDecoder`, and
    /// it was spent on this store's serial queue, i.e. in front of the batched capture
    /// writes, at every launch. The four values are columns now (`appKey`, `appJSON`,
    /// `deviceKey`, `deviceJSON`, `isError`) and the same answer costs **12.8 ms**.
    ///
    /// Two things the column path has to get right, both of which the decode did for
    /// free:
    ///
    /// - **A representative is grouped by *value*, not taken from one row.** The counts
    ///   group by key, but `appReps`/`deviceReps` need a whole `SourceApp`/`SourceDevice`,
    ///   and a device's typing is merged across its flows ("keep the richest typing
    ///   seen"). So the query groups by (key, blob) — a handful of rows, one per distinct
    ///   value, not one per flow — and the merge stays `FlowAggregates.contribute`'s,
    ///   applied once per distinct value rather than once per row.
    /// - **NULL must mean "no app", not "this row predates the column".** A table
    ///   written by an older build has the columns (added by `migrateAddAggregateColumns`)
    ///   and no values in them, which would read as a capture with no app attribution at
    ///   all. `PRAGMA user_version` gates it: below `aggregateSchemaVersion` this takes
    ///   the old decode path *and* backfills, so exactly one launch after the upgrade
    ///   pays the 293 ms it used to pay every time.
    func aggregate() -> FlowAggregates {
        queue.sync {
            writePending()
            guard userVersion >= Self.aggregateSchemaVersion else { return backfillAggregateColumns() }
            return aggregateFromColumns()
        }
    }

    /// The column path. Three statements, none of which reads the `json` blob.
    private func aggregateFromColumns() -> FlowAggregates {
        var aggregates = FlowAggregates()
        // Hosts: the count is all the sidebar needs, there is no representative.
        forEachRow("SELECT host, COUNT(*) FROM flows WHERE host IS NOT NULL GROUP BY host;") { stmt in
            guard let host = Self.text(stmt, 0) else { return }
            aggregates.addHost(host, count: Int(sqlite3_column_int64(stmt, 1)))
        }
        // Apps and devices: grouped by (key, encoded value), so a distinct value is
        // decoded once however many flows carry it.
        forEachRow("""
        SELECT appJSON, COUNT(*) FROM flows WHERE appKey IS NOT NULL AND appJSON IS NOT NULL
        GROUP BY appKey, appJSON;
        """) { stmt in
            guard let blob = Self.blob(stmt, 0), let app = try? decoder.decode(SourceApp.self, from: blob) else { return }
            aggregates.addApp(app, count: Int(sqlite3_column_int64(stmt, 1)))
        }
        forEachRow("""
        SELECT deviceJSON, COUNT(*) FROM flows WHERE deviceKey IS NOT NULL AND deviceJSON IS NOT NULL
        GROUP BY deviceKey, deviceJSON;
        """) { stmt in
            guard let blob = Self.blob(stmt, 0),
                  let device = try? decoder.decode(SourceDevice.self, from: blob) else { return }
            aggregates.addDevice(device, count: Int(sqlite3_column_int64(stmt, 1)))
        }
        // The joint count the nested sidebar needs. A fourth `GROUP BY` rather than
        // something folded out of the two above: an app's total and a device's total
        // overlap, and no arithmetic over them recovers how many of Safari's flows
        // were the phone's. Keys only — both representatives are already decoded by
        // the two statements above, so this reads no blob.
        forEachRow("""
        SELECT deviceKey, appKey, COUNT(*) FROM flows
        WHERE deviceKey IS NOT NULL AND appKey IS NOT NULL
        GROUP BY deviceKey, appKey;
        """) { stmt in
            guard let deviceKey = Self.text(stmt, 0), let appKey = Self.text(stmt, 1) else { return }
            aggregates.addDeviceApp(
                deviceKey: deviceKey, appKey: appKey, count: Int(sqlite3_column_int64(stmt, 2))
            )
        }
        forEachRow("SELECT COUNT(*) FROM flows WHERE isError = 1;") { stmt in
            aggregates.addErrors(Int(sqlite3_column_int64(stmt, 0)))
        }
        return aggregates
    }

    /// The old decode-everything path, plus the one-time write of what it decoded into
    /// the aggregate columns. Runs on a table written by a build that predates them.
    ///
    /// Backfilling *here* rather than at open is deliberate: this is already the call
    /// that decodes the whole table, it already runs off the actor at boot, and doing it
    /// in `init` would put the same cost in front of the engine starting instead.
    private func backfillAggregateColumns() -> FlowAggregates {
        var aggregates = FlowAggregates()
        let flows = decodeRows(sql: "SELECT json FROM flows;")
        for flow in flows { aggregates.contribute(flow) }

        var stmt: OpaquePointer?
        let sql = "UPDATE flows SET appKey = ?, appJSON = ?, deviceKey = ?, deviceJSON = ?, isError = ? WHERE id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            // The counts above are still correct; only the fast path is unavailable, and
            // the next launch will try again (user_version stays put).
            Log.store.error("""
            Backfilling the flow aggregate columns failed to prepare \
            (\(String(cString: sqlite3_errmsg(self.db)), privacy: .public)); \
            boot aggregation stays on the slow path.
            """)
            return aggregates
        }
        defer { sqlite3_finalize(stmt) }
        exec("BEGIN IMMEDIATE;")
        var written = 0
        for flow in flows {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            if let app = flow.sourceApp {
                sqlite3_bind_text(stmt, 1, app.groupingKey, -1, transient)
                bindBlob(stmt, 2, try? encoder.encode(app))
            } else {
                sqlite3_bind_null(stmt, 1)
                sqlite3_bind_null(stmt, 2)
            }
            if let device = flow.sourceDevice {
                sqlite3_bind_text(stmt, 3, device.groupingKey, -1, transient)
                bindBlob(stmt, 4, try? encoder.encode(device))
            } else {
                sqlite3_bind_null(stmt, 3)
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_int(stmt, 5, FlowAggregates.isError(flow) ? 1 : 0)
            sqlite3_bind_text(stmt, 6, flow.id.uuidString, -1, transient)
            if sqlite3_step(stmt) == SQLITE_DONE { written += 1 }
        }
        exec("COMMIT;")
        // Only claim the fast path once every row actually carries its values — a
        // partial backfill read as complete would under-count for the life of the file.
        if written == flows.count {
            userVersion = Self.aggregateSchemaVersion
        } else {
            Log.store.error("""
            Backfilled \(written) of \(flows.count) flow rows; boot aggregation stays on \
            the slow path and will retry next launch.
            """)
        }
        return aggregates
    }

    /// Step a statement to exhaustion, handing each row to `body`. The three grouped
    /// reads above differ only in their SQL.
    private func forEachRow(_ sql: String, _ body: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.store.error("""
            Aggregating stored flows failed: \
            \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)
            """)
            return
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { body(stmt) }
    }

    private static func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        sqlite3_column_text(stmt, index).map { String(cString: $0) }
    }

    private func countRows() -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM flows;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}
