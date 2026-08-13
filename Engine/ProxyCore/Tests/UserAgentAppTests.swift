import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// Naming the app behind a request that has no local process to resolve.
///
/// This is the only attribution available for a phone, and it is a claim by the
/// client rather than a measurement — so the bar is not "guess well", it is
/// **never produce a bucket that lumps unrelated apps together**. Every case here
/// is a way of failing that bar.
@Suite struct UserAgentAppTests {
    @Test func anAppThatNamesItselfIsTaken() {
        #expect(UserAgentParser.app("YqdCredmex/3.4.1 (Android 16; 2211133C)") == "YqdCredmex")
        #expect(UserAgentParser.app("MyApp/1.0") == "MyApp")
        // A bundle id is what an iOS app's default `User-Agent` leads with, and it
        // is a perfectly good bucket key.
        #expect(UserAgentParser.app("com.example.wallet/2 CFNetwork/1494 Darwin/24.4.0")
            == "com.example.wallet")
    }

    @Test func anHTTPStackIsNotAnApp() {
        // The failure this rule exists for: `okhttp` and `Dalvik` are what *every*
        // Android app's default client says, so accepting them would file the whole
        // phone under one row — worse than saying nothing, because it looks like an
        // answer.
        #expect(UserAgentParser.app("okhttp/4.9.3") == nil)
        #expect(UserAgentParser.app("Dalvik/2.1.0 (Linux; U; Android 16; 2211133C Build/BP2A)") == nil)
        #expect(UserAgentParser.app("CFNetwork/1494.0.7 Darwin/24.4.0") == nil)
        #expect(UserAgentParser.app("python-requests/2.31.0") == nil)
        #expect(UserAgentParser.app("Go-http-client/1.1") == nil)
    }

    @Test func theLibraryListMatchesTheWholeTokenAndNotASubstring() {
        // An app legitimately called `OkHttpDemo` is an app.
        #expect(UserAgentParser.app("OkHttpDemo/1.0") == "OkHttpDemo")
        #expect(UserAgentParser.app("JavaScriptCoreThing/2") == "JavaScriptCoreThing")
    }

    @Test func aBrowserIsNamedByItsBrowserAndNotByMozilla() {
        let safari = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        #expect(UserAgentParser.app(safari) == "Safari")
        let chrome = "Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Chrome/131.0.0.0 Mobile Safari/537.36"
        #expect(UserAgentParser.app(chrome) == "Chrome")
    }

    @Test func aMozillaStringThatNamesNoBrowserNamesNothing() {
        // `client` would answer "Android app" here off the Dalvik token; that is a
        // device descriptor, not an app, and the two questions must not share an
        // answer (see the doc comment on `UserAgentParser.app`).
        #expect(UserAgentParser.app("Mozilla/5.0 (Linux; Android 16) Dalvik/2.1.0") == nil)
    }

    @Test func nothingIsNotAGuess() {
        #expect(UserAgentParser.app(nil) == nil)
        #expect(UserAgentParser.app("") == nil)
        #expect(UserAgentParser.app("   ") == nil)
    }

    @Test func anAttributedRemoteAppSaysWhereTheNameCameFrom() {
        let app = SourceApp.fromUserAgent(name: "YqdCredmex")
        #expect(app.attribution == .userAgent)
        // No pid, and no sentinel standing in for one: a phone's app has no process
        // id on this machine, and a number there would be something a reader could
        // compare and filter on.
        #expect(app.pid == nil)
        #expect(app.groupingKey == "YqdCredmex")
    }

    @Test func aProcessAttributionStaysTheDefault() {
        // Every call site that predates remote attribution builds one of these, and
        // must keep meaning "libproc resolved this".
        #expect(SourceApp(name: "curl", pid: 42).attribution == .process)
    }
}
