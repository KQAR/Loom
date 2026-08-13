import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// Mutual TLS: the identity store's selection/validation rules, and a **real
/// handshake** against a server that demands a client certificate.
///
/// The handshake pair is the load-bearing part. A store test alone can't tell the
/// difference between "the identity was loaded" and "the identity was presented",
/// and the whole feature is the latter — so the same server is asked twice, once
/// with an identity configured for the host and once without, and the second must
/// fail. Bundles are minted with `/usr/bin/openssl` (LibreSSL, always present on
/// macOS) because nothing in the Swift TLS stack writes PKCS#12.
@Suite("Client certificates", .timeLimit(.minutes(1)))
struct ClientCertificateTests {
    // MARK: - Store behaviour

    @Test func picksTheMostSpecificEnabledPatternForAHost() throws {
        let material = try TLSMaterial.make()
        let wildcard = ClientCertificate(hostPattern: "*.corp.example", pkcs12: material.p12, passphrase: material.passphrase)
        let exact = ClientCertificate(hostPattern: "api.corp.example", pkcs12: material.p12, passphrase: material.passphrase)
        let other = ClientCertificate(hostPattern: "other.example", pkcs12: material.p12, passphrase: material.passphrase)
        let config = ClientCertificateConfig(certificates: [wildcard, exact, other], fileURL: nil)

        // Longest pattern wins, so the answer doesn't depend on insertion order.
        #expect(config.identity(forHost: "api.corp.example")?.id == exact.id)
        #expect(config.identity(forHost: "admin.corp.example")?.id == wildcard.id)
        #expect(config.identity(forHost: "unrelated.test") == nil)
    }

    @Test func ignoresDisabledIdentities() throws {
        let material = try TLSMaterial.make()
        var identity = ClientCertificate(hostPattern: "api.corp.example", pkcs12: material.p12, passphrase: material.passphrase)
        identity.isEnabled = false
        let config = ClientCertificateConfig(certificates: [identity], fileURL: nil)
        #expect(config.identity(forHost: "api.corp.example") == nil)
        #expect(try config.context(forHost: "api.corp.example", offeringHTTP2: false) == nil)
    }

    @Test func rejectsAnUnreadableBundleWhenItIsSetNotWhenItIsUsed() throws {
        // The point of validating on the way in: the operator who typed the
        // passphrase is the one who can fix it. A request failing hours later
        // reports the origin's name, not theirs.
        let material = try TLSMaterial.make()
        let config = ClientCertificateConfig(fileURL: nil)

        #expect(throws: ProxyControlError.self) {
            try config.set(ClientCertificate(hostPattern: "api.test", pkcs12: Data("not a p12".utf8)))
        }
        #expect(throws: ProxyControlError.self) {
            try config.set(ClientCertificate(hostPattern: "api.test", pkcs12: material.p12, passphrase: "wrong"))
        }
        #expect(throws: ProxyControlError.self) {
            try config.set(ClientCertificate(hostPattern: "", pkcs12: material.p12, passphrase: material.passphrase))
        }
        #expect(config.all().isEmpty, "nothing invalid should have been stored")

        try config.set(ClientCertificate(hostPattern: "api.test", pkcs12: material.p12, passphrase: material.passphrase))
        #expect(config.all().count == 1)
    }

    @Test func summariesCarryTheParsedLeafAndNeverTheKey() throws {
        let material = try TLSMaterial.make()
        let config = ClientCertificateConfig(fileURL: nil)
        try config.set(ClientCertificate(
            hostPattern: "api.corp.example", pkcs12: material.p12, passphrase: material.passphrase, label: "Corp API"
        ))

        let summary = try #require(config.summaries().first)
        #expect(summary.label == "Corp API")
        #expect(summary.subject?.contains("loom-test-client") == true, "got \(summary.subject ?? "nil")")
        #expect(summary.notAfter != nil)
        #expect(!summary.isExpired(), "freshly minted")
        #expect(summary.problem == nil)
        // The type has no field that could carry the key or passphrase; encoding it
        // is the assertion that a leak can't happen through this surface.
        let encoded = try #require(String(data: try JSONEncoder().encode(summary), encoding: .utf8))
        #expect(!encoded.contains(material.passphrase))
    }

    @Test func summaryReportsAProblemInsteadOfHidingAnUnreadableStoredBundle() throws {
        // Reachable in practice: the file is hand-editable, and a bundle can also be
        // written by an older build. Better a visible `problem` than a handshake
        // failure attributed to the origin.
        let config = ClientCertificateConfig(
            certificates: [ClientCertificate(hostPattern: "api.test", pkcs12: Data("garbage".utf8))],
            fileURL: nil
        )
        let summary = try #require(config.summaries().first)
        #expect(summary.problem != nil)
        #expect(summary.subject == nil)
    }

    @Test func replacesByIDAndDeletes() throws {
        let material = try TLSMaterial.make()
        let config = ClientCertificateConfig(fileURL: nil)
        let identity = ClientCertificate(hostPattern: "a.test", pkcs12: material.p12, passphrase: material.passphrase)
        try config.set(identity)

        var moved = identity
        moved.hostPattern = "b.test"
        try config.set(moved)
        #expect(config.all().count == 1, "same id replaces rather than duplicating")
        #expect(config.identity(forHost: "b.test") != nil)
        #expect(config.identity(forHost: "a.test") == nil)

        #expect(config.delete(id: identity.id))
        #expect(!config.delete(id: identity.id), "deleting twice reports the second as a miss")
    }

    @Test func persistsAcrossInstancesWithOwnerOnlyPermissions() throws {
        let material = try TLSMaterial.make()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-clientcerts-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("client-certificates.json")

        let config = ClientCertificateConfig(fileURL: url)
        try config.set(ClientCertificate(
            hostPattern: "api.corp.example", pkcs12: material.p12, passphrase: material.passphrase
        ))
        config.flush()

        let reloaded = ClientCertificateConfig(fileURL: url)
        #expect(reloaded.identity(forHost: "api.corp.example") != nil)

        // The file holds a private key; owner-only is not optional.
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600, "got \(String(mode?.int16Value ?? -1, radix: 8))")
    }

    // MARK: - Real handshake

    @Test func presentsTheIdentityToAServerThatDemandsOne() async throws {
        let material = try TLSMaterial.make()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { shutdownBlocking(group) }
        let server = try MutualTLSServer(material: material, group: group)
        defer { server.stop() }

        let config = ClientCertificateConfig(
            certificates: [ClientCertificate(
                hostPattern: "127.0.0.1", pkcs12: material.p12, passphrase: material.passphrase
            )],
            fileURL: nil,
            baseConfiguration: material.clientConfiguration
        )
        let forwarder = NIOStreamingForwarder(group: group, clientIdentities: config)

        let url = try #require(URL(string: "https://127.0.0.1:\(server.port)/mtls"))
        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)
        #expect(result.statusCode == 200)
        #expect(result.body == Data("mutual".utf8))
    }

    @Test func withoutAMatchingIdentityTheSameServerRefusesTheHandshake() async throws {
        // The negative half: it proves the test above passed *because* the
        // certificate was presented, not because the server was lenient.
        let material = try TLSMaterial.make()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { shutdownBlocking(group) }
        let server = try MutualTLSServer(material: material, group: group)
        defer { server.stop() }

        let config = ClientCertificateConfig(
            certificates: [ClientCertificate(
                hostPattern: "elsewhere.example", pkcs12: material.p12, passphrase: material.passphrase
            )],
            fileURL: nil,
            baseConfiguration: material.clientConfiguration
        )
        let forwarder = NIOStreamingForwarder(group: group, clientIdentities: config)

        let url = try #require(URL(string: "https://127.0.0.1:\(server.port)/mtls"))
        await #expect(throws: (any Error).self) {
            _ = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)
        }
    }

    // MARK: Failure legibility

    @Test func aRefusedHandshakeNamesWhetherAnIdentityWasPresented() async throws {
        // The diagnosis this exists for. Before it, an mTLS refusal reached the
        // operator as `NIOSSL.NIOSSLError error 3.` — no host, no hint.
        let material = try TLSMaterial.make()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { shutdownBlocking(group) }
        let server = try MutualTLSServer(material: material, group: group)
        defer { server.stop() }

        // No identity matches 127.0.0.1, so the server (which requires one) refuses.
        let config = ClientCertificateConfig(
            certificates: [ClientCertificate(
                hostPattern: "elsewhere.example", pkcs12: material.p12, passphrase: material.passphrase
            )],
            fileURL: nil,
            baseConfiguration: material.clientConfiguration
        )
        let forwarder = NIOStreamingForwarder(group: group, clientIdentities: config)
        let url = try #require(URL(string: "https://127.0.0.1:\(server.port)/mtls"))

        do {
            _ = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)
            Issue.record("the handshake should have failed")
        } catch {
            // `localizedDescription` specifically: that is what `StreamRelay` and the
            // replay path store in `Flow.error`, which is the string every surface reads.
            let message = error.localizedDescription
            #expect(message.contains("127.0.0.1"), "got \(message)")
            #expect(message.contains("no client certificate"), "got \(message)")
            #expect(message.contains("set_client_certificate"), "got \(message)")
            // States what Loom did, never what the server wanted — Loom cannot tell a
            // client-cert requirement from any other handshake failure.
            #expect(!message.lowercased().contains("requires a client certificate"), "got \(message)")
            // …and this really is the mutual-TLS refusal, not us rejecting the
            // server's certificate. Until `baseContext()` existed, the no-identity
            // path used the shared default context, which does not trust this test's
            // throwaway CA — so the handshake died at server-certificate
            // verification and the assertions above passed for the wrong reason.
            #expect(!message.contains("could not verify"), "got \(message)")
        }
    }

    @Test func handshakeContextNamesTheIdentityWhenOneWasPresented() throws {
        // Unit-level, because provoking a *rejection* of a valid certificate needs a
        // second CA the server doesn't trust — more machinery than the message is
        // worth. What matters is which branch the text takes.
        let wrapped = UpstreamTLSError.wrapping(
            NIOSSLError.handshakeFailed(.noError),
            host: "api.corp.example", isTLS: true, identity: "Corp API (*.corp.example)"
        )
        let message = wrapped.localizedDescription
        #expect(message.contains("Loom presented client certificate Corp API (*.corp.example)"), "got \(message)")
        #expect(!message.contains("set_client_certificate"), "advice for the wrong problem")
    }

    /// The failure this suite got wrong: an ordinary bad **server** certificate.
    ///
    /// Loom refuses the peer, so the peer never asked us for anything — yet the
    /// message used to lead with "Loom presented no client certificate … install one
    /// with set_client_certificate", pointing the reader at a write action that
    /// needs their private key and cannot help. Found against a real expired-cert
    /// host; reproduced here offline by declining to trust the test CA.
    @Test func aRejectedServerCertificateIsNotReportedAsAClientCertificateProblem() async throws {
        let material = try TLSMaterial.make()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownBlocking(group) }
        let server = try MutualTLSServer(material: material, group: group)
        defer { server.stop() }

        // No `baseConfiguration`, so the forwarder uses default trust roots and the
        // test CA is unknown to it: a genuine CERTIFICATE_VERIFY_FAILED, not a stub.
        let forwarder = NIOStreamingForwarder(
            group: group,
            clientIdentities: ClientCertificateConfig(certificates: [], fileURL: nil)
        )
        let url = try #require(URL(string: "https://127.0.0.1:\(server.port)/anything"))

        do {
            _ = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)
            Issue.record("the handshake should have failed")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("could not verify"), "got \(message)")
            #expect(!message.contains("set_client_certificate"),
                    "advice for the wrong problem — Loom rejected the server: \(message)")
            #expect(!message.contains("no client certificate"), "got \(message)")
            #expect(message.contains("127.0.0.1"), "got \(message)")
        }
    }

    /// Hostname mismatch is the same class, reached through a typed NIOSSL error
    /// rather than BoringSSL's reason string — so the classifier can't be passing
    /// only because of the string check.
    @Test func aHostnameMismatchIsAlsoAServerCertificateProblem() throws {
        let wrapped = UpstreamTLSError.wrapping(
            NIOSSLExtraError.failedToValidateHostname, host: "api.test", isTLS: true, identity: nil
        )
        let message = wrapped.localizedDescription
        #expect(message.contains("could not verify"), "got \(message)")
        #expect(!message.contains("set_client_certificate"), "got \(message)")
    }

    /// The neutral wording still applies to everything else: a handshake that failed
    /// for a reason Loom can't attribute keeps reporting only what Loom did.
    @Test func anUnattributableHandshakeFailureKeepsTheNeutralWording() throws {
        let wrapped = UpstreamTLSError.wrapping(
            NIOSSLError.handshakeFailed(.noError), host: "api.test", isTLS: true, identity: nil
        )
        let message = wrapped.localizedDescription
        #expect(message.contains("no client certificate"), "got \(message)")
        #expect(!message.contains("could not verify"), "got \(message)")
    }

    @Test func nonTLSFailuresAreLeftAlone() throws {
        // The filter is the load-bearing part: appending a mutual-TLS note to a DNS
        // miss or a refused connection would turn a clear error into a misleading one.
        let plain = ForwarderError.connectionClosed
        #expect(UpstreamTLSError.wrapping(plain, host: "a.test", isTLS: true, identity: nil) is ForwarderError,
                "a mid-exchange close is where TLS 1.3 rejection *and* every ordinary reset land — not attributable")
        #expect(UpstreamTLSError.wrapping(
            NIOSSLError.handshakeFailed(.noError), host: "a.test", isTLS: false, identity: nil
        ) is NIOSSLError, "plain HTTP can't have a handshake problem")
    }

    @Test func aConfiguredButUnloadableIdentityFailsLoudlyRatherThanConnectingWithoutIt() async throws {
        // Connecting anyway would fail the handshake too, but the error would name
        // the origin. The identity is the thing the operator can fix, so it is named.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownBlocking(group) }
        let config = ClientCertificateConfig(
            certificates: [ClientCertificate(hostPattern: "api.test", pkcs12: Data("garbage".utf8))],
            fileURL: nil
        )
        let forwarder = NIOStreamingForwarder(group: group, clientIdentities: config)

        let url = try #require(URL(string: "https://api.test/thing"))
        await #expect(throws: (any Error).self) {
            _ = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)
        }
    }
}

// MARK: - Test material

/// A throwaway CA, a server certificate and a client PKCS#12 bundle, minted with
/// `/usr/bin/openssl` because no Swift TLS API writes PKCS#12.
///
/// Internal rather than file-private: `H2UpstreamTests` needs the same throwaway
/// trust root to stand up an ALPN-speaking origin, and minting a second identical
/// one would cost two more `openssl` invocations per run to say the same thing.
struct TLSMaterial {
    let caPEM: String
    let serverCertPEM: String
    let serverKeyPEM: String
    let p12: Data
    let passphrase = "loom-test-passphrase"

    /// Client TLS configuration that trusts this material's CA — the seam that lets
    /// the handshake tests run through the production context-building path.
    var clientConfiguration: @Sendable () -> TLSConfiguration {
        let caPEM = self.caPEM
        return {
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.trustRoots = .certificates((try? NIOSSLCertificate.fromPEMBytes(Array(caPEM.utf8))) ?? [])
            // The server certificate is issued to an IP, and the forwarder passes no
            // SNI/validation hostname for an IP literal; chain validation is what
            // this test cares about.
            configuration.certificateVerification = .noHostnameVerification
            return configuration
        }
    }

    static func make() throws -> TLSMaterial {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-tls-material-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func path(_ name: String) -> String { directory.appendingPathComponent(name).path }
        let passphrase = "loom-test-passphrase"

        try openssl([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
            "-keyout", path("ca.key"), "-out", path("ca.crt"), "-subj", "/CN=Loom Test CA",
        ])
        for (name, subject) in [("server", "/CN=127.0.0.1"), ("client", "/CN=loom-test-client")] {
            try openssl([
                "req", "-newkey", "rsa:2048", "-nodes",
                "-keyout", path("\(name).key"), "-out", path("\(name).csr"), "-subj", subject,
            ])
            try openssl([
                "x509", "-req", "-in", path("\(name).csr"),
                "-CA", path("ca.crt"), "-CAkey", path("ca.key"),
                "-set_serial", name == "server" ? "2" : "3", "-days", "2",
                "-out", path("\(name).crt"),
            ])
        }
        try openssl([
            "pkcs12", "-export", "-out", path("client.p12"),
            "-inkey", path("client.key"), "-in", path("client.crt"), "-certfile", path("ca.crt"),
            "-passout", "pass:\(passphrase)",
            // LibreSSL's defaults are old enough that BoringSSL may refuse the
            // bundle; name modern algorithms explicitly.
            "-keypbe", "AES-256-CBC", "-certpbe", "AES-256-CBC", "-macalg", "sha256",
        ])

        return TLSMaterial(
            caPEM: try String(contentsOf: directory.appendingPathComponent("ca.crt"), encoding: .utf8),
            serverCertPEM: try String(contentsOf: directory.appendingPathComponent("server.crt"), encoding: .utf8),
            serverKeyPEM: try String(contentsOf: directory.appendingPathComponent("server.key"), encoding: .utf8),
            p12: try Data(contentsOf: directory.appendingPathComponent("client.p12"))
        )
    }

    private static func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TLSMaterialError.opensslFailed(
                arguments.first ?? "?", String(decoding: stderr, as: UTF8.self)
            )
        }
    }
}

enum TLSMaterialError: Error {
    case opensslFailed(String, String)
}

/// A TLS server that **requires** a client certificate issued by the test CA and
/// answers any request with `200 mutual`.
private final class MutualTLSServer {
    let port: Int
    private let channel: Channel

    init(material: TLSMaterial, group: EventLoopGroup) throws {
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: try NIOSSLCertificate.fromPEMBytes(Array(material.serverCertPEM.utf8)).map { .certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(material.serverKeyPEM.utf8), format: .pem))
        )
        configuration.certificateVerification = .noHostnameVerification
        configuration.trustRoots = .certificates(try NIOSSLCertificate.fromPEMBytes(Array(material.caPEM.utf8)))
        let context = try NIOSSLContext(configuration: configuration)

        channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(NIOSSLServerHandler(context: context))
                    .flatMap { channel.pipeline.addHandler(CannedHTTPResponder()) }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
        port = channel.localAddress?.port ?? 0
    }

    func stop() {
        try? channel.close().wait()
    }
}

/// Answers the first complete request head with a fixed HTTP/1.1 response. Kept at
/// the byte level: these tests are about the handshake, not about framing.
private final class CannedHTTPResponder: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var seen = ""

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        seen += buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
        guard seen.contains("\r\n\r\n") else { return }
        seen = ""
        var response = context.channel.allocator.buffer(capacity: 64)
        response.writeString("HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nmutual")
        context.writeAndFlush(wrapOutboundOut(response)).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
