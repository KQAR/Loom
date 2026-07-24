import Testing
import Foundation
@testable import LoomProxyCore
import LoomSharedModels

@Suite final class AuditStoreTests {
    private let fileURL: URL

    init() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-audit-\(UUID())", isDirectory: true)
            .appendingPathComponent("audit.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func entry(_ n: Int, tool: String = "create_rule", succeeded: Bool = true) -> AuditEntry {
        AuditEntry(
            timestamp: Date(timeIntervalSince1970: TimeInterval(n)),
            tool: tool, succeeded: succeeded,
            arguments: #"{"n":\#(n)}"#, detail: "detail\(n)"
        )
    }

    // MARK: Persistence

    @Test func persistence_saveAndRecent_newestFirst() throws {
        let store = try #require(AuditPersistence(fileURL: fileURL))
        store.save(entry(1))
        store.save(entry(2, tool: "delete_rule"))
        let recent = store.recent(limit: 10) // sync read drains the serial write queue
        #expect(recent.count == 2)
        #expect(recent.first?.tool == "delete_rule", "newest first")
        #expect(recent.first?.detail == "detail2")
        #expect(recent.last?.tool == "create_rule")
    }

    @Test func persistence_roundTripsAllFields() throws {
        let store = try #require(AuditPersistence(fileURL: fileURL))
        let e = AuditEntry(tool: "replay_flow", source: .mcp, succeeded: false,
                           arguments: #"{"id":"abc"}"#, detail: "boom")
        store.save(e)
        let back = try #require(store.recent(limit: 1).first)
        #expect(back.id == e.id)
        #expect(back.tool == "replay_flow")
        #expect(back.source == .mcp)
        #expect(back.succeeded == false)
        #expect(back.arguments == #"{"id":"abc"}"#)
        #expect(back.detail == "boom")
    }

    @Test func persistence_prunesOldestOverCap() throws {
        let store = try #require(AuditPersistence(fileURL: fileURL, maxRows: 3))
        for n in 1...6 { store.save(entry(n)) }
        let recent = store.recent(limit: 100)
        #expect(recent.count == 3, "capped to maxRows")
        #expect(recent.map(\.arguments) == [#"{"n":6}"#, #"{"n":5}"#, #"{"n":4}"#], "oldest dropped")
    }

    @Test func persistence_survivesReopen() throws {
        do {
            let store = try #require(AuditPersistence(fileURL: fileURL))
            store.save(entry(1))
            store.flush()
        }
        let reopened = try #require(AuditPersistence(fileURL: fileURL))
        #expect(reopened.recent(limit: 10).count == 1, "trail survives a relaunch")
    }

    // MARK: Store (actor)

    @Test func store_recordThenRecent_newestFirst() async {
        let store = AuditStore(persistence: nil)
        await store.record(entry(1))
        await store.record(entry(2, tool: "set_ssl_scope"))
        let recent = await store.recent(limit: 10)
        #expect(recent.count == 2)
        #expect(recent.first?.tool == "set_ssl_scope")
    }

    @Test func store_boundedToCapacity() async {
        let store = AuditStore(capacity: 2, persistence: nil)
        for n in 1...5 { await store.record(entry(n)) }
        let recent = await store.recent(limit: 100)
        #expect(recent.count == 2, "in-memory ring capped")
        #expect(recent.first?.arguments == #"{"n":5}"#)
    }

    @Test func store_streamDeliversLiveEntries() async {
        let store = AuditStore(persistence: nil)
        let stream = await store.stream()
        await store.record(entry(1, tool: "arm_breakpoint"))
        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received?.tool == "arm_breakpoint")
    }

    @Test func store_loadsPersistedHistoryOnFirstRead() async throws {
        let persistence = try #require(AuditPersistence(fileURL: fileURL))
        persistence.save(entry(1))
        persistence.save(entry(2))
        persistence.flush()
        let store = AuditStore(persistence: persistence)
        let recent = await store.recent(limit: 10)
        #expect(recent.count == 2, "seeds the ring from disk")
        #expect(recent.first?.arguments == #"{"n":2}"#)
    }

    @Test func store_clear_emptiesRingAndDisk() async throws {
        let persistence = try #require(AuditPersistence(fileURL: fileURL))
        let store = AuditStore(persistence: persistence)
        await store.record(entry(1))
        await store.record(entry(2))

        await store.clear()

        #expect(await store.recent(limit: 100).isEmpty, "ring cleared")
        await store.flush() // drain the deleteAll
        #expect(persistence.recent(limit: 100).isEmpty, "durable store cleared")
    }
}
