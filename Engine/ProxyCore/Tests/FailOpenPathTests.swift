import Testing
import Foundation
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
            actions: RuleActions(route: .mock(MockResponseAction(statusCode: 200, bodyText: "{}")))
        )
        let first = RulesConfig(fileURL: url)
        first.add(rule) // mutations persist

        let reloaded = RulesConfig(fileURL: url)
        #expect(reloaded.snapshot().rules.map(\.name) == ["mock home"])
    }

    // MARK: SSL scope

    @Test func interceptionConfig_corruptStoredScope_fallsBackToDisabled() {
        let suite = "com.loom.tests.failopen.\(UUID().uuidString)"
        let defaults = try! #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("garbage".utf8), forKey: "com.loom.sslScope")

        let config = InterceptionConfig(defaults: defaults)
        #expect(config.snapshot().enabled == false, "a corrupt scope must not enable interception by accident")
    }

    @Test func interceptionConfig_goodStoredScope_isRestored() {
        let suite = "com.loom.tests.failopen.\(UUID().uuidString)"
        let defaults = try! #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = InterceptionConfig(defaults: defaults)
        config.update(SSLScope(enabled: true, include: ["api.example.com"]))

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
}
