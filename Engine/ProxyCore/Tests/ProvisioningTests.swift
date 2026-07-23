import Foundation
import NIOPosix
import XCTest
@testable import ProxyCore

final class ProvisioningTests: XCTestCase {
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

    func test_landingPage_showsProxyAddressAndFingerprint() throws {
        let content = try makeContent()
        let resource = content.resource(for: "/")
        XCTAssertEqual(resource.status, .ok)
        XCTAssertTrue(resource.contentType.contains("text/html"))
        let html = String(decoding: resource.body, as: UTF8.self)
        XCTAssertTrue(html.contains("192.168.1.42"))
        XCTAssertTrue(html.contains("9090"))
        XCTAssertTrue(html.contains(content.fingerprint))
        XCTAssertTrue(html.contains("/loom.mobileconfig"))
        XCTAssertTrue(html.contains("/loom-ca.crt"))
    }

    func test_landingPage_localizesByAcceptLanguage() throws {
        let content = try makeContent()

        let zh = String(decoding: content.resource(for: "/", acceptLanguage: "zh-CN,zh;q=0.9,en;q=0.8").body, as: UTF8.self)
        XCTAssertTrue(zh.contains("在此设备上配置 Loom"))
        XCTAssertTrue(zh.contains("lang=\"zh-Hans\""))

        let en = String(decoding: content.resource(for: "/", acceptLanguage: "en-US,en;q=0.9").body, as: UTF8.self)
        XCTAssertTrue(en.contains("Set up Loom on this device"))
        XCTAssertTrue(en.contains("lang=\"en\""))
    }

    func test_landingPage_hasPlatformScopedStepsAndTrustShortcuts() throws {
        let content = try makeContent()
        let html = String(decoding: content.resource(for: "/").body, as: UTF8.self)
        // Per-platform install buttons.
        XCTAssertTrue(html.contains("class=\"btn ios-only\""))
        XCTAssertTrue(html.contains("class=\"btn android-only\""))
        // No App-Prefs jump — iOS Safari rejects those; the trust step is text-only.
        XCTAssertFalse(html.contains("App-Prefs:"))
        // Step 2 still offers the iOS profile install.
        XCTAssertTrue(html.contains("href=\"/loom.mobileconfig\""))
        // JS narrows the visible platform.
        XCTAssertTrue(html.contains("querySelectorAll"))
    }

    func test_crtEndpoint_returnsRawDER() throws {
        let content = try makeContent()
        let resource = content.resource(for: "/loom-ca.crt")
        XCTAssertEqual(resource.status, .ok)
        XCTAssertEqual(resource.contentType, "application/x-x509-ca-cert")
        XCTAssertEqual(resource.downloadName, "loom-ca.crt")
        XCTAssertEqual(resource.body, Array(content.caDER))
    }

    func test_pemEndpoint_returnsPEM() throws {
        let content = try makeContent()
        let resource = content.resource(for: "/loom-ca.pem")
        XCTAssertEqual(String(decoding: resource.body, as: UTF8.self), content.caPEM)
    }

    func test_mobileConfig_embedsBase64DERAndRootPayload() throws {
        let content = try makeContent()
        let resource = content.resource(for: "/loom.mobileconfig")
        XCTAssertEqual(resource.contentType, "application/x-apple-aspen-config")
        let xml = String(decoding: resource.body, as: UTF8.self)
        XCTAssertTrue(xml.contains("com.apple.security.root"))
        // The <data> block is line-wrapped; stripping whitespace must reveal the
        // unwrapped base64 of the DER.
        let unwrapped = content.caDER.base64EncodedString()
        let collapsed = xml.components(separatedBy: .whitespacesAndNewlines).joined()
        XCTAssertTrue(collapsed.contains(unwrapped))
    }

    func test_unknownPath_is404() throws {
        let content = try makeContent()
        XCTAssertEqual(content.resource(for: "/nope").status, .notFound)
    }

    /// End-to-end: bind the server on loopback and fetch the DER over real HTTP.
    func test_server_servesOverHTTP() async throws {
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

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, content.caDER)
    }
}
