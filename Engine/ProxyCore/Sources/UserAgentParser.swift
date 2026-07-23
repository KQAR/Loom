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
