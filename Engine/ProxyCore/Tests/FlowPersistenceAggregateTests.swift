import Testing
import Foundation
import SQLite3
@testable import LoomProxyCore
import LoomSharedModels

/// `FlowPersistence.aggregate()` counts the whole table without decoding it — a
/// `GROUP BY` over columns rather than a `JSONDecoder` per row (293 ms → 12.8 ms on a
/// full 20 000-row table, of which only 3.6 ms was ever SQLite's).
///
/// That swap is only sound if two things hold, and neither is visible from the call
/// site: the grouped fold must equal the row-by-row fold exactly, and a NULL column
/// must never be read as "this flow had no app" when it really means "this row was
/// written before the column existed". One suite for both, because they fail the same
/// way — a sidebar quietly counting the wrong thing.
@Suite final class FlowPersistenceAggregateTests {
    private let directory: URL
    private let fileURL: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-aggregate-\(UUID())", isDirectory: true)
        fileURL = directory.appendingPathComponent("flows.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func flow(
        _ n: Int,
        host: String = "api.test",
        status: Int = 200,
        failed: Bool = false,
        app: SourceApp? = nil,
        device: SourceDevice? = nil
    ) -> Flow {
        let started = Date(timeIntervalSince1970: TimeInterval(n))
        let response = CapturedResponse(statusCode: status, headers: [])
        return Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "https://\(host)/\(n)", headers: []),
            startedAt: started,
            outcome: failed
                ? .failed(FlowError("boom"), at: started.addingTimeInterval(0.1), partialResponse: nil)
                : .completed(response, at: started.addingTimeInterval(0.1)),
            sourceApp: app,
            sourceDevice: device
        )
    }

    /// A capture with every shape the fold distinguishes: several hosts, several apps,
    /// a device whose typing arrives across two flows, a 4xx, a 5xx and a transport
    /// failure that answered 200 before dying.
    private func mixedCapture() -> [Flow] {
        let safari = SourceApp(name: "Safari", bundleID: "com.apple.Safari", pid: 1)
        let curl = SourceApp(name: "curl", bundleID: nil, pid: 2)
        let untyped = SourceDevice(ip: "192.168.1.9", kind: .lan)
        var typed = untyped
        typed.platform = "iOS"
        var flows: [Flow] = []
        for n in 1 ... 12 { flows.append(flow(n, host: "api.test", app: safari)) }
        for n in 13 ... 18 { flows.append(flow(n, host: "cdn.test", app: curl)) }
        for n in 19 ... 21 { flows.append(flow(n, host: "api.test", status: 404, app: safari)) }
        flows.append(flow(22, host: "api.test", status: 500))
        flows.append(flow(23, host: "other.test", failed: true))
        flows.append(flow(24, host: "api.test", device: untyped))
        flows.append(flow(25, host: "api.test", device: typed))
        return flows
    }

    private func decodedAggregate(of flows: [Flow]) -> FlowAggregates {
        var expected = FlowAggregates()
        for flow in flows { expected.contribute(flow) }
        return expected
    }

    // MARK: The grouped fold equals the row-by-row fold

    @Test func theColumnPathMatchesFoldingEveryFlow() throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let flows = mixedCapture()
        for flow in flows { persistence.save(flow) }
        persistence.flush()

        let aggregates = persistence.aggregate()
        let expected = decodedAggregate(of: flows)

        #expect(aggregates.hostCounts == expected.hostCounts)
        #expect(aggregates.appCounts == expected.appCounts)
        #expect(aggregates.appReps == expected.appReps)
        #expect(aggregates.deviceCounts == expected.deviceCounts)
        #expect(aggregates.errorCount == expected.errorCount)
        // The device's typing arrived on the second of its two flows; the merge has to
        // survive being applied per *distinct value* instead of per row.
        #expect(aggregates.deviceReps["192.168.1.9"]?.platform == "iOS")
        #expect(aggregates.deviceReps == expected.deviceReps)
    }

    @Test func anEmptyTableAggregatesToNothing() throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        #expect(persistence.aggregate() == FlowAggregates())
    }

    /// A replaced flow (the same id upserted again as it completes) must be counted
    /// once, not twice — `INSERT OR REPLACE` is what makes that true and the columns
    /// have to travel with the replacement.
    @Test func aReplacedRowIsCountedOnce() throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let started = Date(timeIntervalSince1970: 1)
        let id = UUID()
        let request = CapturedRequest(method: "GET", url: "https://api.test/1", headers: [])
        let app = SourceApp(name: "Safari", bundleID: "com.apple.Safari", pid: 1)
        persistence.save(Flow(
            id: id, request: request, startedAt: started,
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: started)
        ))
        // The same exchange again, now attributed and now an error.
        persistence.save(Flow(
            id: id, request: request, startedAt: started,
            outcome: .completed(CapturedResponse(statusCode: 500, headers: []), at: started),
            sourceApp: app
        ))
        persistence.flush()

        let aggregates = persistence.aggregate()
        #expect(aggregates.hostCounts["api.test"] == 1)
        #expect(aggregates.appCounts["com.apple.Safari"] == 1)
        #expect(aggregates.errorCount == 1, "the replacement is a 500; the row it replaced was not")
    }

    // MARK: A table written before the columns existed

    /// The failure this guards is silent and total: an upgraded install's rows have the
    /// columns (added by the migration) and nothing in them, so a column-side count
    /// would report a capture with no apps, no devices and no errors — while the
    /// sidebar's hosts, which *were* always a column, looked right.
    @Test func aLegacyTableIsBackfilledRatherThanMiscounted() throws {
        let flows = mixedCapture()
        writeLegacyTable(flows)

        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let aggregates = persistence.aggregate()
        let expected = decodedAggregate(of: flows)
        #expect(aggregates.appCounts == expected.appCounts)
        #expect(aggregates.deviceCounts == expected.deviceCounts)
        #expect(aggregates.errorCount == expected.errorCount)
        #expect(aggregates.hostCounts == expected.hostCounts)

        // Backfilled, so the *next* aggregation takes the column path and gets the same
        // answer — which is the whole point of paying for the decode once.
        #expect(persistence.aggregate() == aggregates)
    }

    /// A fresh table is created with the columns already in place, so it must not be
    /// treated as needing a backfill (the version marker is what says so).
    @Test func aFreshTableIsAlreadyOnTheColumnPath() throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        persistence.save(flow(1, app: SourceApp(name: "curl", bundleID: nil, pid: 2)))
        persistence.flush()
        #expect(persistence.aggregate().appCounts == ["curl": 1])
        // Re-open: the marker is on the file, not on the instance.
        let reopened = try #require(FlowPersistence(fileURL: fileURL))
        #expect(reopened.aggregate().appCounts == ["curl": 1])
    }

    /// Write the pre-0.0.24 table by hand — the eight original columns, no
    /// `user_version` — so the migration and the backfill are exercised against the
    /// shape they actually have to read, not against a table this build wrote.
    private func writeLegacyTable(_ flows: [Flow]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(fileURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_exec(db, """
        CREATE TABLE flows (
            id TEXT PRIMARY KEY, startedAt REAL, host TEXT, method TEXT, status INTEGER,
            json BLOB, reqBody BLOB, respBody BLOB
        );
        """, nil, nil, nil)
        let encoder = JSONEncoder()
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, """
        INSERT INTO flows (id, startedAt, host, method, status, json, reqBody, respBody)
        VALUES (?, ?, ?, ?, ?, ?, NULL, NULL);
        """, -1, &stmt, nil)
        for flow in flows {
            let json = (try? encoder.encode(flow.strippingBodies())) ?? Data()
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, flow.id.uuidString, -1, transient)
            sqlite3_bind_double(stmt, 2, flow.startedAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, flow.host ?? "", -1, transient)
            sqlite3_bind_text(stmt, 4, flow.request.method, -1, transient)
            if let status = flow.statusCode { sqlite3_bind_int(stmt, 5, Int32(status)) } else { sqlite3_bind_null(stmt, 5) }
            json.withUnsafeBytes { _ = sqlite3_bind_blob(stmt, 6, $0.baseAddress, Int32(json.count), transient) }
            #expect(sqlite3_step(stmt) == SQLITE_DONE)
        }
        sqlite3_finalize(stmt)
    }
}
