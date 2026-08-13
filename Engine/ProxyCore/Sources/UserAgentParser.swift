import Foundation

/// Best-effort classification of a request's `User-Agent` into an OS platform and
/// a client/browser, to type a `SourceDevice`. Pure heuristics over the UA string
/// — deliberately conservative: an unknown UA yields `nil`, never a wrong guess.
///
/// Order matters: several tokens co-occur (Android UAs also say "Linux"; Edge and
/// Chrome both say "Chrome"; Safari appears in Chrome UAs), so the more specific
/// check wins and runs first.
enum UserAgentParser {
    /// Returns `(platform, client)`, either of which may be `nil`.
    static func parse(_ userAgent: String?) -> (platform: String?, client: String?) {
        guard let ua = userAgent, !ua.isEmpty else { return (nil, nil) }
        return (platform(ua), client(ua))
    }

    /// The app a `User-Agent` names, for a request whose origin has no local
    /// process to resolve — every request from a phone or any other LAN device.
    ///
    /// This is a **weaker** claim than `client`, deliberately, and the two are not
    /// the same question. `client` types the *device* and answers "roughly what
    /// kind of thing is this" — it is happy to say `Android app` for a Dalvik UA,
    /// which is a fine label for a device row and a useless one for an app row,
    /// because every app on the phone would land in one bucket named after the
    /// runtime. This answers "which app", so it returns nil rather than a category
    /// whenever the string names no product.
    ///
    /// Three rules, each of which is a way to get a wrong bucket:
    ///
    /// - **A browser is a browser.** A Safari or Chrome UA leads with `Mozilla/5.0`
    ///   and names the engine, not the page — so the recognised browser name is the
    ///   app, and the version soup after it is dropped.
    /// - **An HTTP library is not an app.** `okhttp/4.9`, `Dalvik/2.1.0`,
    ///   `CFNetwork/1494`, `python-requests/2.31` are the *stack*, and bucketing by
    ///   them would put every app on the device together. When the string leads with
    ///   one of those and nothing else, this returns nil and the flow stays
    ///   unattributed — honestly, rather than filed under "okhttp".
    /// - **Otherwise the leading product token wins** (`YqdCredmex/3.4.1 (…)` →
    ///   `YqdCredmex`), which is the convention an app that sets its own UA follows.
    ///
    /// It is a claim by the client, not a measurement: `SourceApp.attribution`
    /// records that, and nothing downstream should treat it as identity.
    static func app(_ userAgent: String?) -> String? {
        guard let ua = userAgent?.trimmingCharacters(in: .whitespaces), !ua.isEmpty else { return nil }
        // A browser names itself somewhere in the middle of the string; take the
        // recognised name rather than the `Mozilla` the string opens with.
        if ua.hasPrefix("Mozilla/") { return client(ua).flatMap { $0 == "Android app" ? nil : $0 } }
        let token = productToken(ua)
        guard let token, !token.isEmpty else { return nil }
        return isTransportLibrary(token) ? nil : token
    }

    /// The leading `product` of a UA, per RFC 9110 §10.1.5 (`product = token
    /// ["/" product-version]`) — everything before the first `/`, space or `(`.
    private static func productToken(_ ua: String) -> String? {
        let end = ua.firstIndex { $0 == "/" || $0 == " " || $0 == "(" } ?? ua.endIndex
        let token = String(ua[ua.startIndex ..< end])
        return token.isEmpty ? nil : token
    }

    /// Names that identify an HTTP stack rather than the app using it. Matched
    /// case-insensitively and exactly against the leading product token — a
    /// substring test would swallow an app legitimately called `OkHttpDemo`.
    private static let transportLibraries: Set<String> = [
        "okhttp", "dalvik", "java", "cfnetwork", "darwin", "python-requests",
        "urllib", "urllib3", "axios", "node-fetch", "undici", "go-http-client",
        "libcurl", "apachehttpclient", "httpclient", "ktor-client", "alamofire",
        "volley", "cronet", "unirest", "restsharp", "guzzlehttp", "postmanruntime",
    ]

    private static func isTransportLibrary(_ token: String) -> Bool {
        transportLibraries.contains(token.lowercased())
    }

    private static func platform(_ ua: String) -> String? {
        if ua.contains("iPhone") { return "iOS" }
        if ua.contains("iPad") { return "iPadOS" }
        if ua.contains("Android") { return "Android" }        // before Linux (Android UAs say Linux)
        if ua.contains("Macintosh") || ua.contains("Mac OS X") { return "macOS" }
        if ua.contains("Windows") { return "Windows" }
        if ua.contains("CrOS") { return "ChromeOS" }
        if ua.contains("Linux") { return "Linux" }
        // Apple system networking stack — platform unknown but Apple-family.
        if ua.contains("CFNetwork") || ua.contains("Darwin") { return "Apple" }
        return nil
    }

    private static func client(_ ua: String) -> String? {
        if ua.contains("Edg/") || ua.contains("EdgiOS") { return "Edge" }
        if ua.contains("OPR/") || ua.contains("Opera") { return "Opera" }
        if ua.contains("CriOS") { return "Chrome" }            // Chrome on iOS
        if ua.contains("FxiOS") || ua.contains("Firefox") { return "Firefox" }
        if ua.contains("Chrome") || ua.contains("Chromium") { return "Chrome" } // after Edge/Opera
        if ua.contains("Safari") { return "Safari" }           // after Chrome (Chrome UAs include Safari)
        if ua.hasPrefix("curl/") { return "curl" }
        if ua.hasPrefix("Wget") { return "Wget" }
        if ua.contains("okhttp") { return "okhttp" }
        if ua.contains("Dalvik") { return "Android app" }
        // Fall back to the leading product token (e.g. "MyApp/1.2" -> "MyApp").
        if let slash = ua.firstIndex(where: { $0 == "/" || $0 == " " }) {
            let head = String(ua[ua.startIndex ..< slash])
            if !head.isEmpty, head != "Mozilla" { return head }
        }
        return nil
    }
}
