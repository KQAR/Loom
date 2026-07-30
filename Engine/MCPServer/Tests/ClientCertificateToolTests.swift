import Testing
import Foundation
import LoomSharedModels
@testable import MCPServer

/// The mutual-TLS tool surface. The load-bearing test here is the audit one: these
/// are the first write tools whose arguments carry a **credential**, and the audit
/// trail is durable and on disk.
@MainActor
@Suite struct ClientCertificateToolTests {
    private func makeExecutor(_ engine: StubEngine) -> MCPToolExecutor {
        MCPToolExecutor(engine: engine, appVersion: "9.9", protocolVersion: "2025-06-18")
    }

    private func json(_ string: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }

    private let bundle = Data("pretend-pkcs12-bytes".utf8)

    @Test func setStoresTheIdentityAndEchoesTheParsedSummary() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)

        let result = try await executor.call(name: "set_client_certificate", arguments: [
            "host_pattern": "api.corp.example",
            "pkcs12_base64": bundle.base64EncodedString(),
            "passphrase": "s3cret",
            "label": "Corp API",
        ])
        let payload = try json(result)
        #expect(payload["saved"] as? Bool == true)
        #expect(payload["hostPattern"] as? String == "api.corp.example")
        // Echoes the *stored* summary, so the operator sees which identity landed
        // rather than a replay of what they typed.
        #expect(payload["subject"] as? String == "CN=stub-client")

        #expect(engine.storedClientCertificates.count == 1)
        #expect(engine.storedClientCertificates.first?.pkcs12 == bundle)
        #expect(engine.storedClientCertificates.first?.passphrase == "s3cret")
    }

    @Test func theAuditTrailRecordsTheActionWithoutTheKeyOrPassphrase() async throws {
        // The audit trail exists so a human can see what an agent did to real
        // traffic; it must not double as a copy of the operator's key material.
        let engine = StubEngine()
        let executor = makeExecutor(engine)

        _ = try await executor.call(name: "set_client_certificate", arguments: [
            "host_pattern": "api.corp.example",
            "pkcs12_base64": bundle.base64EncodedString(),
            "passphrase": "s3cret",
        ])

        let entry = try #require(engine.recordedAudits.first)
        #expect(entry.tool == "set_client_certificate")
        #expect(entry.succeeded)
        // The host is what supervision needs to see; the credential is not.
        #expect(entry.arguments.contains("api.corp.example"))
        #expect(!entry.arguments.contains("s3cret"))
        #expect(!entry.arguments.contains(bundle.base64EncodedString()))
        #expect(entry.arguments.contains("<redacted>"))
        // The argument names survive, so "a certificate was installed" is still legible.
        #expect(entry.arguments.contains("pkcs12_base64"))
    }

    @Test func listNeverReturnsTheBundleOrThePassphrase() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        _ = try await executor.call(name: "set_client_certificate", arguments: [
            "host_pattern": "api.corp.example",
            "pkcs12_base64": bundle.base64EncodedString(),
            "passphrase": "s3cret",
        ])

        let result = try await executor.call(name: "list_client_certificates", arguments: [:])
        #expect(!result.contains("s3cret"))
        #expect(!result.contains(bundle.base64EncodedString()))
        #expect(result.contains("api.corp.example"))
        // Expiry is stated, not left to be derived: an expired identity fails a
        // handshake exactly like a missing one.
        #expect(result.contains("expired"))
    }

    @Test func idReplacesInsteadOfAddingASecondIdentity() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        let first = try json(try await executor.call(name: "set_client_certificate", arguments: [
            "host_pattern": "a.test", "pkcs12_base64": bundle.base64EncodedString(),
        ]))
        let id = try #require(first["id"] as? String)

        _ = try await executor.call(name: "set_client_certificate", arguments: [
            "id": id, "host_pattern": "b.test", "pkcs12_base64": bundle.base64EncodedString(),
        ])
        #expect(engine.storedClientCertificates.count == 1)
        #expect(engine.storedClientCertificates.first?.hostPattern == "b.test")
    }

    @Test func deleteRemovesAndReportsAnUnknownID() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        let saved = try json(try await executor.call(name: "set_client_certificate", arguments: [
            "host_pattern": "a.test", "pkcs12_base64": bundle.base64EncodedString(),
        ]))
        let id = try #require(saved["id"] as? String)

        _ = try await executor.call(name: "delete_client_certificate", arguments: ["id": id])
        #expect(engine.storedClientCertificates.isEmpty)

        await #expect(throws: (any Error).self) {
            _ = try await executor.call(name: "delete_client_certificate", arguments: ["id": UUID().uuidString])
        }
        // A failed write is audited too — the record is of the attempt, not the outcome.
        #expect(engine.recordedAudits.contains { $0.tool == "delete_client_certificate" && !$0.succeeded })
    }

    @Test func rejectsMalformedArguments() async throws {
        let executor = makeExecutor(StubEngine())
        await #expect(throws: (any Error).self) {
            _ = try await executor.call(name: "set_client_certificate", arguments: [
                "pkcs12_base64": bundle.base64EncodedString(),
            ])
        }
        await #expect(throws: (any Error).self) {
            _ = try await executor.call(name: "set_client_certificate", arguments: [
                "host_pattern": "a.test", "pkcs12_base64": "not base64 !!!",
            ])
        }
        await #expect(throws: (any Error).self) {
            _ = try await executor.call(name: "delete_client_certificate", arguments: ["id": "not-a-uuid"])
        }
    }

    @Test func aStoreRejectionSurfacesAsAToolFailure() async throws {
        // The store validates the bundle on the way in; the tool must relay that
        // message rather than a generic error, because the passphrase is the thing
        // the operator can fix.
        let engine = StubEngine()
        engine.clientCertificateSetError = ProxyControlError.invalidClientCertificate("wrong passphrase")
        let executor = makeExecutor(engine)

        await #expect(throws: (any Error).self) {
            _ = try await executor.call(name: "set_client_certificate", arguments: [
                "host_pattern": "a.test", "pkcs12_base64": bundle.base64EncodedString(),
            ])
        }
        let entry = try #require(engine.recordedAudits.first)
        #expect(!entry.succeeded)
        #expect(entry.detail.contains("wrong passphrase"))
    }
}
