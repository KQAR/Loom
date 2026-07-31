import Foundation
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// `exportedPEMPath` is what gates the panel's machine-wide "manual trust"
/// command (`security add-trusted-cert <path>`). It was set only by
/// `exportCACertificate()` and held in memory, so a relaunch made an export that
/// was still sitting on disk invisible: the command silently vanished and the
/// human had to press Export… again to see the path for a file already there.
///
/// It now reports what is actually on disk.
@Suite struct ExportedCAVisibilityTests {
    private func exportURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-export-vis-\(UUID())", isDirectory: true)
            .appendingPathComponent("loom-ca.pem")
    }

    @Test func noExportYet_reportsNoPath() async {
        let url = exportURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = ProxyEngine(forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore(), caExportURL: url)

        #expect(await engine.certificateStatus().exportedPEMPath == nil,
                "nothing has been written, so there is no path to show a command for")
    }

    @Test func afterExporting_reportsThePath() async throws {
        let url = exportURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let engine = ProxyEngine(forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore(), caExportURL: url)

        _ = try await engine.exportCACertificate()
        #expect(await engine.certificateStatus().exportedPEMPath == url.path)
    }

    @Test func anExistingExportSurvivesARelaunch() async throws {
        // The regression: a second engine over the same export path (what a relaunch
        // is) must still see the file. Before, exportedPEMPath was in-memory only, so
        // this came back nil and the manual-trust command disappeared from the panel.
        let url = exportURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = ProxyEngine(forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore(), caExportURL: url)
        _ = try await first.exportCACertificate()

        let relaunched = ProxyEngine(forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore(), caExportURL: url)
        #expect(await relaunched.certificateStatus().exportedPEMPath == url.path,
                "an export already on disk must stay visible across a relaunch")
    }

    @Test func aDeletedExportStopsBeingReported() async throws {
        // The other direction: don't offer a command naming a file the user removed.
        let url = exportURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let engine = ProxyEngine(forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore(), caExportURL: url)
        _ = try await engine.exportCACertificate()
        try FileManager.default.removeItem(at: url)

        let relaunched = ProxyEngine(forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore(), caExportURL: url)
        #expect(await relaunched.certificateStatus().exportedPEMPath == nil)
    }
}
