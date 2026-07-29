import Testing
import Foundation
@testable import LoomProxyCore
import LoomSharedModels

/// Everything under `~/Library/Application Support/com.loom` is owner-only, and
/// that is asserted here rather than left to each writer's discipline.
///
/// `ca-store.pem` and `rules.json` always set it; `flows.sqlite` and `audit.sqlite`
/// did not — they were created with a bare `createDirectory` and inherited the
/// umask, typically `0644` under a `0755` directory. Those two hold whole captured
/// request and response bodies and every write tool's arguments, so on a shared Mac
/// they leak more than the CA key the other writers were careful about.
@Suite("Storage permissions")
struct StoragePermissionsTests {
    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-perms-\(UUID())", isDirectory: true)
        return url
    }

    @Test func flowDatabase_andItsDirectory_areOwnerOnly() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("flows.sqlite")

        let store = try #require(FlowPersistence(fileURL: url))
        store.flush()

        #expect(try mode(of: directory) == 0o700, "the directory mode is what covers -wal/-shm too")
        #expect(try mode(of: url) == 0o600)
    }

    @Test func auditDatabase_andItsDirectory_areOwnerOnly() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audit.sqlite")

        let store = try #require(AuditPersistence(fileURL: url))
        store.save(AuditEntry(tool: "set_rule", succeeded: true, arguments: #"{"x":1}"#, detail: ""))
        store.flush()

        #expect(try mode(of: directory) == 0o700)
        #expect(try mode(of: url) == 0o600)
    }

    /// SQLite's sidecars appear on first write, not at open — the reason the
    /// directory mode carries the guarantee rather than the file chmod.
    @Test func walSiblings_areNotWorldReadable() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("flows.sqlite")

        let store = try #require(FlowPersistence(fileURL: url))
        store.save(Flow(
            id: UUID(),
            request: CapturedRequest(method: "POST", url: "https://api.test/login", headers: [],
                                     body: Data(#"{"password":"hunter2"}"#.utf8)),
            startedAt: Date(timeIntervalSince1970: 0),
            outcome: .completed(CapturedResponse(statusCode: 200, headers: [], body: nil),
                                at: Date(timeIntervalSince1970: 1))
        ))
        store.flush()

        for sibling in ["-wal", "-shm"] {
            let path = url.path + sibling
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let mode = try mode(of: URL(fileURLWithPath: path))
            #expect(mode & 0o077 == 0, "\(sibling) must not be group/world readable (got \(String(mode, radix: 8)))")
        }
    }

    /// A directory created by an earlier build (0755) must be tightened on open,
    /// not left as-is — `createDirectory` only applies attributes to directories it
    /// actually creates.
    @Test func preexistingLooseDirectory_isTightened() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        #expect(try mode(of: directory) == 0o755, "precondition: starts loose")

        _ = try #require(FlowPersistence(fileURL: directory.appendingPathComponent("flows.sqlite")))
        #expect(try mode(of: directory) == 0o700, "opening the store must tighten an inherited directory")
    }
}
