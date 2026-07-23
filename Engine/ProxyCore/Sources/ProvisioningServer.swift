import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// The material a phone needs to trust Loom, plus the proxy address to point at.
/// Immutable and `Sendable` so the NIO handler can hold it across event loops.
struct ProvisioningContent: Sendable {
    let caPEM: String
    let caDER: Data
    let fingerprint: String
    let commonName: String
    let proxyHost: String
    let proxyPort: Int
}

/// A tiny LAN-facing HTTP server that hands a phone everything it needs to
/// intercept its traffic through Loom: an instructions landing page, the root CA
/// in PEM/DER form, and an iOS `.mobileconfig` profile that installs the CA. The
/// provisioning QR (see `ProxyEngine.startPhoneOnboarding`) encodes this server's
/// root URL, so one scan opens the page.
///
/// Deliberately separate from the proxy listener: it speaks origin-form HTTP to a
/// browser, not proxy-form CONNECT/absolute-URI requests, and binds the LAN
/// interface only while phone onboarding is active.
final class ProvisioningServer {
    private let group: EventLoopGroup
    private var channel: Channel?

    init(group: EventLoopGroup) {
        self.group = group
    }

    /// Bind and start serving. Pass `port: 0` to let the OS assign one; the bound
    /// port is returned.
    func start(host: String, port: Int, content: ProvisioningContent) async throws -> Int {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(ProvisioningHandler(content: content))
                }
            }

        let channel = try await bootstrap.bind(host: host, port: port).get()
        self.channel = channel
        return channel.localAddress?.port ?? port
    }

    func stop() async {
        try? await channel?.close().get()
        channel = nil
    }
}

/// Routes a browser GET to one of the provisioning resources and writes a
/// self-closing HTTP/1.1 response. Business logic (page/profile bytes) lives on
/// `ProvisioningContent`.
private final class ProvisioningHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let content: ProvisioningContent
    private var path = "/"
    private var acceptLanguage: String?

    init(content: ProvisioningContent) {
        self.content = content
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            // Strip query/fragment — routing is on the path only.
            path = String(head.uri.prefix { $0 != "?" && $0 != "#" })
            acceptLanguage = head.headers.first(name: "Accept-Language")
        case .body:
            break
        case .end:
            respond(context: context)
        }
    }

    private func respond(context: ChannelHandlerContext) {
        let resource = content.resource(for: path, acceptLanguage: acceptLanguage)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: resource.contentType)
        headers.add(name: "Content-Length", value: String(resource.body.count))
        if let filename = resource.downloadName {
            headers.add(name: "Content-Disposition", value: "attachment; filename=\"\(filename)\"")
        }
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Cache-Control", value: "no-store")

        let head = HTTPResponseHead(version: .http1_1, status: resource.status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: resource.body.count)
        buffer.writeBytes(resource.body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}

// MARK: - Resources

extension ProvisioningContent {
    struct Resource {
        var status: HTTPResponseStatus
        var contentType: String
        var body: [UInt8]
        var downloadName: String?
    }

    func resource(for path: String, acceptLanguage: String? = nil) -> Resource {
        switch path {
        case "/", "/index.html":
            let html = landingHTML(PageLanguage.from(acceptLanguage))
            return Resource(status: .ok, contentType: "text/html; charset=utf-8", body: Array(html.utf8), downloadName: nil)
        case "/loom-ca.pem":
            return Resource(status: .ok, contentType: "application/x-pem-file", body: Array(caPEM.utf8), downloadName: "loom-ca.pem")
        case "/loom-ca.crt", "/loom-ca.cer", "/loom-ca.der":
            // application/x-x509-ca-cert prompts the cert-install UI on iOS/Android.
            return Resource(status: .ok, contentType: "application/x-x509-ca-cert", body: Array(caDER), downloadName: "loom-ca.crt")
        case "/loom.mobileconfig":
            return Resource(status: .ok, contentType: "application/x-apple-aspen-config", body: Array(mobileConfigXML.utf8), downloadName: "Loom.mobileconfig")
        default:
            return Resource(status: .notFound, contentType: "text/plain; charset=utf-8", body: Array("Not found".utf8), downloadName: nil)
        }
    }

    /// iOS/macOS configuration profile that installs the root CA. Plain
    /// certificate install only — a global HTTP-proxy payload requires a
    /// supervised device, so the phone sets the proxy manually (shown on the page).
    var mobileConfigXML: String {
        let der = caDER.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let payloadUUID = UUID().uuidString
        let profileUUID = UUID().uuidString
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>PayloadContent</key>
            <array>
                <dict>
                    <key>PayloadCertificateFileName</key>
                    <string>loom-ca.cer</string>
                    <key>PayloadContent</key>
                    <data>
        \(der)
                    </data>
                    <key>PayloadDescription</key>
                    <string>Adds the \(xmlEscape(commonName)) so Loom can decrypt HTTPS.</string>
                    <key>PayloadDisplayName</key>
                    <string>\(xmlEscape(commonName))</string>
                    <key>PayloadIdentifier</key>
                    <string>com.loom.ca.\(payloadUUID)</string>
                    <key>PayloadType</key>
                    <string>com.apple.security.root</string>
                    <key>PayloadUUID</key>
                    <string>\(payloadUUID)</string>
                    <key>PayloadVersion</key>
                    <integer>1</integer>
                </dict>
            </array>
            <key>PayloadDescription</key>
            <string>Install the Loom root certificate to allow HTTPS interception on this device.</string>
            <key>PayloadDisplayName</key>
            <string>Loom Root Certificate</string>
            <key>PayloadIdentifier</key>
            <string>com.loom.profile.\(profileUUID)</string>
            <key>PayloadOrganization</key>
            <string>Loom</string>
            <key>PayloadRemovalDisallowed</key>
            <false/>
            <key>PayloadType</key>
            <string>Configuration</string>
            <key>PayloadUUID</key>
            <string>\(profileUUID)</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
        </plist>
        """
    }

    /// Onboarding landing page, localized (zh/en) from the request's
    /// Accept-Language. Self-contained inline CSS + a little JS that reveals the
    /// trust-step shortcut buttons for the visiting platform. Hex colors are fine
    /// here — this is served HTML, not a SwiftUI view.
    func landingHTML(_ lang: PageLanguage) -> String {
        let zh = lang == .zh
        let htmlLang = zh ? "zh-Hans" : "en"
        let title = zh ? "配置 Loom" : "Set up Loom"
        let heading = zh ? "在此设备上配置 Loom" : "Set up Loom on this device"
        let sub = zh ? "让本设备的流量经由 Loom,并信任其根证书。"
                     : "Route this device's traffic through Loom and trust its certificate."
        let step1 = zh ? "设置 HTTP 代理" : "Set the HTTP proxy"
        let step1Tail = zh ? "在 Wi‑Fi 设置中,将 HTTP 代理设为:" : "in your Wi‑Fi settings to:"
        let step2 = zh ? "安装 Loom 证书" : "Install the Loom certificate"
        let btnProfile = zh ? "安装描述文件(iOS)" : "Install profile (iOS)"
        let btnCrt = zh ? "下载 .crt(Android)" : "Download .crt (Android)"
        let step3 = zh ? "信任证书" : "Trust the certificate"
        let iosDesc = zh ? "iOS:先安装描述文件,再前往 设置 › 通用 › 关于本机 › 证书信任设置 开启完全信任。"
                         : "On iOS: install the profile, then Settings › General › About › Certificate Trust Settings to enable full trust."
        let androidDesc = zh ? "Android:下载 .crt 后,前往 设置 › 安全 › 加密与凭据 › 安装证书 › CA 证书 安装。"
                             : "On Android: after downloading the .crt, install it under Settings › Security › Encryption & credentials › Install a certificate › CA certificate."
        let shortcutHint = zh ? "iOS 不允许网页直接跳转到系统设置;请按上面的路径手动前往开启“完全信任”。"
                              : "iOS doesn't let web pages open Settings directly — follow the path above to enable full trust manually."
        let certLabel = zh ? "证书:" : "Certificate:"

        return """
        <!DOCTYPE html>
        <html lang="\(htmlLang)">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(title)</title>
            <style>
                :root { color-scheme: light dark; }
                * { box-sizing: border-box; }
                body { font: -apple-system-body, system-ui, sans-serif; margin: 0; padding: 24px;
                       max-width: 560px; margin-inline: auto; line-height: 1.5; }
                h1 { font-size: 1.5rem; margin: 0 0 4px; }
                .sub { color: #8a8a8e; margin: 0 0 24px; }
                ol { padding-left: 1.2rem; }
                li { margin-bottom: 20px; }
                .addr { font: 1.1rem ui-monospace, SFMono-Regular, Menlo, monospace;
                        background: rgba(127,127,127,0.15); padding: 8px 12px; border-radius: 8px;
                        display: inline-block; user-select: all; }
                .btn { display: inline-block; background: #0a84ff; color: #fff; text-decoration: none;
                       padding: 12px 18px; border-radius: 10px; font-weight: 600; margin: 6px 8px 6px 0; }
                .btn.secondary { background: rgba(127,127,127,0.2); color: inherit; }
                .fp { font: 0.8rem ui-monospace, SFMono-Regular, Menlo, monospace; color: #8a8a8e;
                      word-break: break-all; margin-top: 8px; }
                .note { font-size: 0.85rem; color: #8a8a8e; margin: 8px 0; }
            </style>
        </head>
        <body>
            <h1>\(heading)</h1>
            <p class="sub">\(sub)</p>
            <ol>
                <li>
                    <strong>\(step1)</strong> \(step1Tail)<br>
                    <span class="addr">\(xmlEscape(proxyHost)) : \(proxyPort)</span>
                </li>
                <li>
                    <strong>\(step2)</strong><br>
                    <a class="btn ios-only" href="/loom.mobileconfig">\(btnProfile)</a>
                    <a class="btn android-only" href="/loom-ca.crt">\(btnCrt)</a>
                    <a class="btn secondary" href="/loom-ca.pem">.pem</a>
                    <div class="fp">SHA-256: \(xmlEscape(fingerprint))</div>
                </li>
                <li>
                    <strong>\(step3)</strong>
                    <div class="ios-only">
                        <p class="note">\(iosDesc)</p>
                        <p class="note">\(shortcutHint)</p>
                    </div>
                    <div class="android-only">
                        <p class="note">\(androidDesc)</p>
                    </div>
                </li>
            </ol>
            <p class="note">\(certLabel) \(xmlEscape(commonName))</p>
            <script>
              (function() {
                var ua = navigator.userAgent || "";
                var isIOS = /iPhone|iPad|iPod/.test(ua) || (ua.indexOf("Mac") >= 0 && "ontouchend" in document);
                var isAndroid = /Android/.test(ua);
                function toggle(sel, on) {
                  var els = document.querySelectorAll(sel);
                  for (var i = 0; i < els.length; i++) { els[i].style.display = on ? "" : "none"; }
                }
                // Show only the visiting platform's steps; unknown → keep both.
                if (isIOS) { toggle(".android-only", false); }
                else if (isAndroid) { toggle(".ios-only", false); }
              })();
            </script>
        </body>
        </html>
        """
    }

    private func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Landing-page language, chosen from the request's `Accept-Language` (primary
/// tag only). Defaults to English for anything non-Chinese.
enum PageLanguage {
    case zh, en

    static func from(_ acceptLanguage: String?) -> PageLanguage {
        let primary = acceptLanguage?
            .split(separator: ",").first?
            .split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces)
            .lowercased() ?? ""
        return primary.hasPrefix("zh") ? .zh : .en
    }
}
