import Testing
import Foundation
import SQLite3
@testable import LoomProxyCore
import LoomSharedModels

/// Loom fails *open* in several places — a corrupt CA store regenerates, an
/// unreadable rules file starts with no rules, a bad SSL scope falls back to
/// disabled. Failing open is the right call (the proxy keeps working), but each
/// one silently changes what the operator is looking at, and the operator here is
/// an agent that can't watch a console. Those paths now log at error level.
///
/// A `Logger` call can't be asserted on directly, so what's pinned here is the
/// branch structure the logging documents: which inputs take the degraded path,
/// and what the degraded path actually does.
@Suite final class FailOpenPathTests {
    private let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-failopen-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: CA store

    /// No file yet is the normal first run — nil, and nothing alarming to report.
    @Test func caStore_missingFile_loadsNil() throws {
        let store = FileCAStore(fileURL: directory.appendingPathComponent("absent.pem"))
        #expect(try store.load() == nil)
    }

    /// A file that exists but can't be parsed is a different thing entirely: the
    /// caller mints a *new* root CA, so the CA the user already trusted stops
    /// working and every HTTPS interception fails until they trust the new one.
    @Test func caStore_corruptFile_loadsNil_ratherThanThrowing() throws {
        let url = directory.appendingPathComponent("corrupt.pem")
        try Data("not a CA blob at all".utf8).write(to: url)
        let store = FileCAStore(fileURL: url)
        #expect(try store.load() == nil, "fails open so the proxy still starts")
    }

    @Test func caStore_nonUTF8File_loadsNil() throws {
        let url = directory.appendingPathComponent("binary.pem")
        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: url)
        #expect(try FileCAStore(fileURL: url).load() == nil)
    }

    @Test func caStore_roundTripsAGoodBlob() throws {
        let url = directory.appendingPathComponent("good.pem")
        let store = FileCAStore(fileURL: url)
        let material = CAMaterial(certificatePEM: "CERT", privateKeyPEM: "KEY")
        try store.save(material)
        let loaded = try #require(try store.load())
        #expect(loaded.certificatePEM == "CERT")
        #expect(loaded.privateKeyPEM == "KEY")
    }

    // MARK: Rules

    /// Every rule vanishing is the dangerous part: traffic an agent believes is
    /// mocked or re-mapped quietly reaches the real upstream instead.
    @Test func rulesConfig_corruptFile_startsEmpty() {
        let url = directory.appendingPathComponent("rules.json")
        try? Data("{ not json".utf8).write(to: url)
        let config = RulesConfig(fileURL: url)
        #expect(config.snapshot().rules.isEmpty)
    }

    @Test func rulesConfig_goodFile_roundTrips() throws {
        let url = directory.appendingPathComponent("rules-ok.json")
        let rule = TrafficRule(
            name: "mock home", match: RuleMatch(urlPattern: "*/home"),
            actions: RuleActions(route: .mock(MockResponseAction(statusCode: 200, body: .text("{}"))))
        )
        let first = RulesConfig(fileURL: url)
        first.add(rule) // mutations persist
        first.flush()

        let reloaded = RulesConfig(fileURL: url)
        #expect(reloaded.snapshot().rules.map(\.name) == ["mock home"])
    }

    // MARK: SSL scope

    @Test func interceptionConfig_corruptStoredScope_fallsBackToDisabled() throws {
        let suite = "com.loom.tests.failopen.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("garbage".utf8), forKey: "com.loom.sslScope")

        let config = InterceptionConfig(defaults: defaults)
        #expect(config.snapshot().enabled == false, "a corrupt scope must not enable interception by accident")
    }

    @Test func interceptionConfig_goodStoredScope_isRestored() throws {
        let suite = "com.loom.tests.failopen.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = InterceptionConfig(defaults: defaults)
        config.update(SSLScope(enabled: true, include: ["api.example.com"]))
        config.flush()

        let reloaded = InterceptionConfig(defaults: defaults)
        #expect(reloaded.snapshot().enabled)
        #expect(reloaded.snapshot().include == ["api.example.com"])
    }

    // MARK: Rule application

    /// The one that misleads rather than degrades: the rule matched, so it is
    /// reported in `appliedRules`, but an unparseable destination means the request
    /// went to its original origin. Reading the flow alone, a redirect appears to
    /// have happened when it did not — hence the error log.
    @Test func mapRemote_unparseableDestination_keepsOriginalURL_butStillReportsTheRule() {
        let rule = TrafficRule(
            name: "to staging", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mapRemote(MapRemoteAction(destination: "not a url")))
        )
        let original = URL(string: "https://api.example.com/v1/home")!
        let plan = RuleEngine.planRequest(
            state: RulesState(enabled: true, rules: [rule]),
            method: "GET", url: original, headers: [], body: nil
        )
        #expect(plan.url == original, "the request is unchanged")
        #expect(plan.appliedRules.map(\.name) == ["to staging"], "…but the rule is still reported")
    }

    @Test func mapRemote_validDestination_rewritesTheOrigin() {
        let rule = TrafficRule(
            name: "to staging", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mapRemote(MapRemoteAction(destination: "https://staging.example.com")))
        )
        let plan = RuleEngine.planRequest(
            state: RulesState(enabled: true, rules: [rule]),
            method: "GET", url: URL(string: "https://api.example.com/v1/home")!, headers: [], body: nil
        )
        #expect(plan.url.absoluteString == "https://staging.example.com/v1/home")
    }

    /// mapLocal already answers with an honest 404 rather than falling through to
    /// the real upstream; the log says why.
    @Test func mapLocal_unreadableFile_serves404NamingThePath() {
        let missing = directory.appendingPathComponent("nope.json").path
        let result = RuleApplyingForwarder.serveLocalFile(MapLocalAction(path: missing))
        #expect(result.statusCode == 404)
        #expect(String(decoding: result.body, as: UTF8.self).contains(missing))
    }

    // MARK: Durable stores — injected faults

    /// A path SQLite cannot open at all (here: a directory). `init?` fails, the
    /// caller falls back to a ring-only store, and capture keeps working — flows
    /// just don't survive the quit.
    @Test func flowPersistence_unopenablePath_isNil_andCaptureContinues() async {
        #expect(FlowPersistence(fileURL: directory) == nil, "a directory is not a database file")

        // What the app does with that nil: ring-only, still fully functional.
        let store = FlowStore(persistence: nil)
        let flow = Self.completedFlow()
        await store.upsert(flow)
        #expect(await store.flow(id: flow.id)?.id == flow.id)
    }

    /// The nastier shape: the file exists and `sqlite3_open` *succeeds*, but it
    /// isn't a database, so every statement fails (`SQLITE_NOTADB`). Nothing throws
    /// — writes are dropped and reads come back empty — so the ring keeps serving
    /// while the durable store is silently a black hole. That's the case the
    /// batch-level "N of M flows failed to persist" log exists for.
    @Test func flowPersistence_fileThatIsNotADatabase_dropsWritesWithoutCrashing() async throws {
        let corrupt = directory.appendingPathComponent("flows.sqlite")
        try Data("this is definitely not a sqlite database".utf8).write(to: corrupt)

        let persistence = try #require(FlowPersistence(fileURL: corrupt), "sqlite3_open succeeds on any file")
        let store = FlowStore(capacity: 2, persistence: persistence)

        let flow = Self.completedFlow()
        await store.upsert(flow)
        persistence.flush()

        #expect(persistence.recent(limit: 10).isEmpty, "nothing landed")
        #expect(persistence.flow(id: flow.id) == nil)
        // The ring is unaffected — capture and detail reads keep working…
        #expect(await store.flow(id: flow.id)?.id == flow.id)
        // …until the flow ages out, at which point read-through finds nothing.
        await store.upsert(Self.completedFlow())
        await store.upsert(Self.completedFlow())
        #expect(await store.flow(id: flow.id) == nil,
                "a broken durable store means an aged-out flow is genuinely gone")
    }

    /// A row that exists but whose JSON no longer decodes (a schema change shipped
    /// against old rows) must be skipped, not crash the read and not abort the rest
    /// of the history.
    @Test func flowPersistence_undecodableRow_isSkipped_andTheRestSurvive() throws {
        let fileURL = directory.appendingPathComponent("flows.sqlite")
        let good = Self.completedFlow()
        do {
            let persistence = try #require(FlowPersistence(fileURL: fileURL))
            persistence.save(good)
            persistence.flush()
        }

        // Corrupt one row's JSON behind the store's back.
        try Self.execSQL("UPDATE flows SET json = X'6E6F7065';", at: fileURL) // "nope"

        let reopened = try #require(FlowPersistence(fileURL: fileURL))
        #expect(reopened.recent(limit: 10).isEmpty, "the undecodable row is dropped, not surfaced as garbage")
        #expect(reopened.flow(id: good.id) == nil)

        // A second, intact row still reads back — one bad row doesn't poison the read.
        let fresh = Self.completedFlow()
        reopened.save(fresh)
        reopened.flush()
        #expect(reopened.recent(limit: 10).map(\.id) == [fresh.id])
    }

    /// Same fault on the audit trail. Losing it is a supervision failure rather
    /// than a data one — the human can no longer see what the agent did — so it
    /// must degrade quietly rather than take a write tool down with it.
    @Test func auditPersistence_fileThatIsNotADatabase_neverThrows() async throws {
        let corrupt = directory.appendingPathComponent("audit.sqlite")
        try Data("nor is this".utf8).write(to: corrupt)

        let persistence = try #require(AuditPersistence(fileURL: corrupt))
        let store = AuditStore(persistence: persistence)
        await store.record(AuditEntry(tool: "replay_flow", succeeded: true, arguments: "{}", detail: "ok"))
        await store.flush()

        #expect(persistence.recent(limit: 10).isEmpty, "nothing landed on disk")
        // The in-memory trail still serves the UI and `get_audit_log` this session.
        #expect(await store.recent(limit: 10).count == 1)
    }

    // MARK: Helpers

    private static func completedFlow() -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "https://api.example.test/x", headers: []),
            startedAt: Date(),
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date())
        )
    }

    /// Run one statement against the database file directly, so a test can inject
    /// damage the store's own API would never produce.
    private static func execSQL(_ sql: String, at fileURL: URL) throws {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        try #require(sqlite3_open(fileURL.path, &handle) == SQLITE_OK)
        try #require(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK,
                     "\(String(cString: sqlite3_errmsg(handle)))")
    }
}
