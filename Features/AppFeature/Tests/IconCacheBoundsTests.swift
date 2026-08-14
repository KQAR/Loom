import Testing
import AppKit
@testable import AppFeature
import LoomSharedModels

/// CLAUDE.md: "every in-memory collection has an explicit cap". The two icon
/// caches were the exceptions — a plain dictionary each, one decoded `NSImage` per
/// distinct host / app bundle, never evicted. Loom is a menu-bar app meant to sit
/// resident for days against arbitrary traffic, so "bounded by how many hosts you
/// visit" is not a bound.
@Suite("Icon cache bounds")
@MainActor
struct IconCacheBoundsTests {
    /// The favicon map stays a dictionary (so `@Observable` can track it) and is
    /// bounded by hand, evicting the oldest host.
    @Test func faviconCache_evictsOldestPastTheCap() {
        // Its own instance, not `shared`: these tests fill the cache to its cap, and
        // one test's leftovers must not decide another's outcome.
        let loader = FaviconLoader()
        let cap = loader.maxIcons
        let hosts = (0 ..< (cap + 50)).map { "host-\($0).cache-bounds.test" }

        for host in hosts { loader.store(nil, for: host) }

        #expect(loader.icons.count <= cap, "the map must not grow past its cap (got \(loader.icons.count))")
        #expect(loader.icons[hosts[0]] == nil, "the oldest host was evicted")
        #expect(loader.icons.index(forKey: hosts[hosts.count - 1]) != nil, "the newest host is retained")
    }

    /// Re-recording a host must not add a second slot for it, or the eviction list
    /// would drift out of step with the map and start evicting live entries early.
    @Test func faviconCache_repeatedHostDoesNotGrowTheOrder() {
        // Its own instance, not `shared`: these tests fill the cache to its cap, and
        // one test's leftovers must not decide another's outcome.
        let loader = FaviconLoader()
        let host = "repeat.cache-bounds.test"
        let before = loader.icons.count
        for _ in 0 ..< 20 { loader.store(nil, for: host) }
        #expect(loader.icons.count == before + 1)
    }

    /// `AppIconLoader` used to be an `NSCache`, which was fine while nothing observed
    /// it. It now resolves icons asynchronously — a synchronous
    /// `NSWorkspace.icon(forFile:)` miss measured 24 ms inside a row body — so a view
    /// must be able to observe an icon arriving, and an `NSCache` mutation is invisible
    /// to `@Observable`. Same dictionary-plus-hand-rolled-cap shape as the favicons.
    @Test func appIconCache_evictsOldestPastTheCap() {
        let loader = AppIconLoader()
        let cap = loader.maxIcons
        let paths = (0 ..< (cap + 20)).map { "/Applications/App-\($0).app" }

        for path in paths { loader.store(nil, for: path) }

        #expect(loader.icons.count <= cap, "the map must not grow past its cap (got \(loader.icons.count))")
        #expect(loader.icons[paths[0]] == nil, "the oldest bundle was evicted")
        #expect(loader.icons.index(forKey: paths[paths.count - 1]) != nil, "the newest bundle is retained")
    }

    /// Same drift guard as the favicon map: re-recording a path must not add a second
    /// slot in the eviction order.
    @Test func appIconCache_repeatedPathDoesNotGrowTheOrder() {
        let loader = AppIconLoader()
        let path = "/Applications/Repeat.app"
        let before = loader.icons.count
        for _ in 0 ..< 20 { loader.store(nil, for: path) }
        #expect(loader.icons.count == before + 1)
    }
}

/// The App column's fallback glyph follows *attribution*, not "has a bundle".
/// A phone app and a local CLI are both bundle-less; drawing them alike is how
/// a WeChat row reads as a terminal.
@Suite struct AppIconFallbackTests {
    @Test func aUserAgentAppUsesTheDashedQuestionMark() {
        #expect(AppIconView.fallbackGlyph(for: .fromUserAgent(name: "WeChat")) == "questionmark.app.dashed")
    }

    @Test func aLocalProcessWithoutABundleUsesTheTerminalGlyph() {
        #expect(AppIconView.fallbackGlyph(for: SourceApp(name: "curl", pid: 1)) == "terminal")
    }

    @Test func anUnresolvedOriginUsesTheDashedQuestionMark() {
        #expect(AppIconView.fallbackGlyph(for: nil) == "questionmark.app.dashed")
    }
}
