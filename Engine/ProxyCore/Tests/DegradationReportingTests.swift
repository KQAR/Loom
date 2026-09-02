import Foundation
import LoomSharedModels
import Testing

@testable import LoomProxyCore

/// The engine fails open by design — and every one of those paths used to report
/// itself to `os_log` and nowhere else, which is one reader: a human with Console
/// open. The operator is an agent, and the human is looking at a menu-bar panel.
///
/// These pin the *returning* half. Each case is a real corrupt file rather than an
/// injected error, because what is being tested is that the fallback still happens
/// **and** is now visible, not that a mock was called.
@Suite("Fail-open paths report themselves", .timeLimit(.minutes(1)))
struct DegradationReportingTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-degradation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The worst of them: rules that will not load mean traffic the operator
    /// believes is mocked, mapped or blocked goes to the real upstream.
    @Test func unreadableRules_areReportedNotJustLogged() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("rules.json")
        try Data("not json".utf8).write(to: file)
        let log = DegradationLog()

        let config = RulesConfig(fileURL: file, degradations: log)

        #expect(config.snapshot().rules.isEmpty, "fails open — that part is by design")
        let reported = try #require(log.current.first)
        #expect(reported.kind == .rulesUnreadable)
        #expect(reported.count == 1)
        // The consequence, not just the error: this is what an agent reads before
        // trusting `list_rules`.
        #expect(reported.detail.contains("real upstream"))
    }

    /// A write that cannot land is invisible in the worst way: this session behaves
    /// exactly as asked, and the next one silently does not.
    @Test func rulesThatCannotBeWritten_areReported() async throws {
        let directory = try temporaryDirectory()
        // A *file* where the rules directory should be, so creating it fails.
        let blocked = directory.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blocked)
        let log = DegradationLog()

        let config = RulesConfig(fileURL: blocked.appendingPathComponent("rules.json"), degradations: log)
        config.add(TrafficRule(
            name: "block ads", match: RuleMatch(urlPattern: "*ads*"),
            actions: RuleActions(route: .block)
        ))

        // The persist is queued; wait for the report rather than for a fixed delay.
        var reported: EngineDegradation?
        for _ in 0..<50 where reported == nil {
            reported = log.current.first { $0.kind == .rulesNotPersisted }
            if reported == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        let entry = try #require(reported, "a lost rules write must be reported")
        #expect(entry.detail.contains("could not be written"))
        // The rule is still live in memory — failing open is the point.
        #expect(config.snapshot().rules.count == 1)
    }

    /// The most invisible failure in the engine: the *new* CA works perfectly, and
    /// every client that trusted the old one fails its handshake with nothing to
    /// point at.
    @Test func aRegeneratedCA_isReported() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("ca-store.pem")
        try Data("not a CA".utf8).write(to: file)
        let log = DegradationLog()

        let store = FileCAStore(fileURL: file, degradations: log)
        #expect(try store.load() == nil, "unusable material must not be returned")

        let reported = try #require(log.current.first)
        #expect(reported.kind == .certificateAuthorityRegenerated)
        #expect(reported.detail.contains("trust"))
    }

    /// A write action that happened with nothing recording it is the one failure the
    /// audit trail must not have — it is the whole of Loom's supervision story.
    @Test func anUnopenableAuditDatabase_isReported() throws {
        let directory = try temporaryDirectory()
        let blocked = directory.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blocked)
        let log = DegradationLog()

        let store = AuditPersistence(
            fileURL: blocked.appendingPathComponent("nested/audit.sqlite"), degradations: log
        )

        #expect(store == nil, "an unopenable store must not pretend to be one")
        let reported = try #require(log.current.first)
        #expect(reported.kind == .auditUnavailable)
    }

    /// One entry per kind, counted. A list that grew per event would be a leak on
    /// the one surface meant to say "this is wrong" — an encode failure recurs per
    /// flow.
    @Test func repeatedFailures_areCountedNotAccumulated() {
        let log = DegradationLog()
        log.record(.flowHistoryIncomplete, "first")
        log.record(.flowHistoryIncomplete, "second")
        log.record(.auditUnavailable, "audit")

        #expect(log.current.count == 2)
        let flows = log.current.first { $0.kind == .flowHistoryIncomplete }
        #expect(flows?.count == 2)
        // Newest detail wins: the same kind failing for a changing reason is worth
        // seeing latest-first, and `count` already says it is not new.
        #expect(flows?.detail == "second")
    }

    /// An entry that outlives the condition it describes is the same defect as no
    /// entry at all, pointed the other way.
    @Test func aRecoveredWrite_clearsItsEntry() {
        let log = DegradationLog()
        log.record(.rulesNotPersisted, "disk full")
        #expect(log.current.count == 1)

        log.clear(.rulesNotPersisted)
        #expect(log.current.isEmpty)
    }

    /// Held per engine, not globally: a test's fabricated corruption must not leak
    /// into the next engine's status, and an embedder running two gets two answers.
    @Test func aCleanEngine_reportsNothing() async throws {
        let engine = ProxyEngine(forwarder: DegradationStubUpstream(), caStore: InMemoryCAStore())
        _ = try await engine.start(port: 0)
        #expect(await engine.status().degradations.isEmpty)
        await engine.stopForTest()
    }
}

private struct DegradationStubUpstream: UpstreamForwarding {
    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        ForwardResult(statusCode: 200, headers: [], body: Data())
    }
}
