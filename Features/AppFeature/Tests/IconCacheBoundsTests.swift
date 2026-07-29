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

    /// `AppIconLoader` is not observed by any view, so it can use `NSCache` — which
    /// also evicts under memory pressure. This pins that it *has* a limit at all.
    @Test func appIconCache_hasACountLimit() {
        #expect(AppIconLoader.cache.countLimit > 0)
    }
}
