import Foundation
import NIOPosix
import Testing
@testable import ProxyCore

@Suite struct ProvisioningTests {
    private func makeContent() throws -> ProvisioningContent {
        let ca = try CertificateAuthority.loadOrGenerate(store: InMemoryCAStore())
        return ProvisioningContent(
            caPEM: ca.caCertificatePEM(),
            caDER: ca.caCertificateDER(),
            fingerprint: ca.sha256Fingerprint,
            commonName: CertificateAuthority.commonName,
            proxyHost: "192.168.1.42",
            proxyPort: 9090
        )
    }

    @Test func landingPage_showsProxyAddressAndFingerprint() throws {
        let content = try makeContent()
        let resource = content.resource(for: "/")
        #expect(resource.status == .ok)
        #expect(resource.contentType.contains("text/html"))
        let html = String(decoding: resource.body, as: UTF8.self)
        #expect(html.contains("192.168.1.42"))
        #expect(html.contains("9090"))
        #expect(html.contains(content.fingerprint))
        #expect(html.contains("/loom.mobileconfig"))
        #expect(html.contains("/loom-ca.crt"))
    }

    @Test func landingPage_localizesByAcceptLanguage() throws {
        let content = try makeContent()

        let zh = String(decoding: content.resource(for: "/", acceptLanguage: "zh-CN,zh;q=0.9,en;q=0.8").body, as: UTF8.self)
        #expect(zh.contains("在此设备上配置 Loom"))
        #expect(zh.contains("lang=\"zh-Hans\""))

        let en = String(decoding: content.resource(for: "/", acceptLanguage: "en-US,en;q=0.9").body, as: UTF8.self)
        #expect(en.contains("Set up Loom on this device"))
        #expect(en.contains("lang=\"en\""))
    }

    @Test func landingPage_hasPlatformScopedStepsAndTrustShortcuts() throws {
        let content = try makeContent()
        let html = String(decoding: content.resource(for: "/").body, as: UTF8.self)
        // Per-platform install buttons.
        #expect(html.contains("class=\"btn ios-only\""))
        #expect(html.contains("class=\"btn android-only\""))
        // No App-Prefs jump — iOS Safari rejects those; the trust step is text-only.
        #expect(!html.contains("App-Prefs:"))
        // Step 2 still offers the iOS profile install.
        #expect(html.contains("href=\"/loom.mobileconfig\""))
        // JS narrows the visible platform.
        #expect(html.contains("querySelectorAll"))
    }

    @Test func crtEndpoint_returnsRawDER() throws {
        let content = try makeContent()
        let resource = content.resource(for: "/loom-ca.crt")
        #expect(resource.status == .ok)
        #expect(resource.contentType == "application/x-x509-ca-cert")
        #expect(resource.downloadName == "loom-ca.crt")
        #expect(resource.body == Array(content.caDER))
    }

    @Test func pemEndpoint_returnsPEM() throws {
        let content = try makeContent()
        let resource = content.resource(for: "/loom-ca.pem")
        #expect(String(decoding: resource.body, as: UTF8.self) == content.caPEM)
    }

    @Test func mobileConfig_embedsBase64DERAndRootPayload() throws {
        let content = try makeContent()
        let resource = content.resource(for: "/loom.mobileconfig")
        #expect(resource.contentType == "application/x-apple-aspen-config")
        let xml = String(decoding: resource.body, as: UTF8.self)
        #expect(xml.contains("com.apple.security.root"))
        // The <data> block is line-wrapped; stripping whitespace must reveal the
        // unwrapped base64 of the DER.
        let unwrapped = content.caDER.base64EncodedString()
        let collapsed = xml.components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(collapsed.contains(unwrapped))
    }

    @Test func unknownPath_is404() throws {
        let content = try makeContent()
        #expect(content.resource(for: "/nope").status == .notFound)
    }

    /// End-to-end: bind the server on loopback and fetch the DER over real HTTP.
    @Test func server_servesOverHTTP() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let content = try makeContent()
        let server = ProvisioningServer(group: group)
        let port = try await server.start(host: "127.0.0.1", port: 0, content: content)
        defer { Task { await server.stop() } }

        let url = URL(string: "http://127.0.0.1:\(port)/loom-ca.crt")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:] // ignore any system proxy
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(for: request)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data == content.caDER)
    }
}
