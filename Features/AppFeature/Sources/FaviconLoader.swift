import AppKit
import LoomSharedModels
import SwiftUI

/// Loads and caches per-host favicons for the sidebar / host column — the
/// Chrome-tab look. Pure presentation, so it lives outside TCA state (like
/// `AsyncImage`): views ask for a host's icon and re-render when it arrives.
///
/// Privacy: favicons are fetched directly from each origin's `/favicon.ico`
/// (a host the user already connected to) — never via a third-party favicon
/// service that would leak the browsing history. The fetch **bypasses** the
/// system proxy so it can't loop back into Loom and pollute the capture.
@MainActor
@Observable
final class FaviconLoader {
    static let shared = FaviconLoader()

    /// host → icon. A present-but-nil value means "tried, none available" so we
    /// stop retrying and fall back to the globe.
    ///
    /// Stays a dictionary rather than becoming an `NSCache`: `@Observable` tracks
    /// the read of this property in `FaviconView.body`, and an `NSCache` mutation
    /// is invisible to it — views would stop refreshing when an icon arrives.
    /// Bounded by hand instead, below.
    private(set) var icons: [String: NSImage?] = [:]

    /// Insertion order, so the cap can evict the oldest host. Without this the
    /// dictionary grew one entry per distinct host forever — the one collection in
    /// the app (with `AppIconLoader`) that ignored the "every collection has an
    /// explicit cap" rule, in a process designed to stay resident for days across
    /// arbitrary traffic.
    private var insertionOrder: [String] = []
    /// Far above any plausible visible set, so eviction can't thrash with the rows
    /// on screen; and an evicted host that reappears is refilled from the disk
    /// cache without a network fetch. Internal so the bound is assertable.
    let maxIcons = 512

    private var inFlight: Set<String> = []
    private let diskDir: URL?

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:] // never route favicon fetches through Loom
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 6
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    /// `shared` is the instance the app uses — a process-wide cache tied to no
    /// view's lifetime. Internal rather than private so a test can take its own and
    /// not inherit whatever hosts a previous test cached.
    init() {
        diskDir = LoomPaths.cachesDirectory?.appendingPathComponent("favicons", isDirectory: true)
        if let diskDir { try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true) }
    }

    /// Kick off a load if this host hasn't been resolved yet. Idempotent.
    func ensure(_ host: String) {
        guard !host.isEmpty, icons[host] == nil, !inFlight.contains(host) else { return }
        inFlight.insert(host)
        let cacheURL = cacheURL(for: host)

        Task { [weak self, session] in
            // Disk cache first — survives relaunches, avoids refetching. Read off
            // the main actor: this used to be a synchronous Data(contentsOf:) +
            // decode inline in `ensure`, i.e. main-thread file I/O once per new
            // host, serialized across a first paint full of new hosts.
            if let cached = await Task.detached(priority: .utility, operation: { Self.diskImage(at: cacheURL) }).value {
                self?.store(cached, for: host)
                self?.inFlight.remove(host)
                return
            }
            guard let self else { return }
            let fetched = await Self.fetchFavicon(host: host, session: session)
            if let bytes = fetched?.bytes, let cacheURL {
                // Cache the fetched bytes as-is (NSImage decodes ico and png alike
                // on read) — re-encoding to PNG on the main actor was pure cost.
                Task.detached(priority: .utility) { try? bytes.write(to: cacheURL, options: .atomic) }
            }
            store(fetched?.image, for: host) // nil marks "none available" so we don't retry
            inFlight.remove(host)
        }
    }

    /// Record an answer and evict the oldest once past the cap.
    func store(_ image: NSImage?, for host: String) {
        if icons[host] == nil { insertionOrder.append(host) }
        icons[host] = image
        while insertionOrder.count > maxIcons {
            let oldest = insertionOrder.removeFirst()
            icons.removeValue(forKey: oldest)
        }
    }

    // MARK: - Fetch

    private static func fetchFavicon(host: String, session: URLSession) async -> (image: NSImage, bytes: Data)? {
        guard let url = URL(string: "https://\(host)/favicon.ico") else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              !data.isEmpty,
              let image = NSImage(data: data), image.isValid, image.size.width > 0
        else { return nil }
        return (image, data)
    }

    // MARK: - Disk cache

    private func cacheURL(for host: String) -> URL? {
        // Host is a DNS name / IP — safe as a filename, but sanitize defensively.
        let safe = host.replacingOccurrences(of: "/", with: "_")
        return diskDir?.appendingPathComponent("\(safe).png")
    }

    /// `nonisolated static` so the read runs on whatever detached task calls it —
    /// never the main actor (see `ensure`). Writes are the fetched bytes, written
    /// detached in `ensure` as well.
    private nonisolated static func diskImage(at url: URL?) -> NSImage? {
        guard let url,
              let data = try? Data(contentsOf: url), !data.isEmpty,
              let image = NSImage(data: data), image.isValid
        else { return nil }
        return image
    }
}

/// A host's favicon, falling back to the system globe until (or unless) one loads.
struct FaviconView: View {
    let host: String
    /// A plain reference, not `@ObservedObject`/`@State`: `@Observable` tracks the
    /// `icons` read in `body` directly, and the loader is a process-wide singleton
    /// whose lifetime must not be tied to any one view's.
    private let loader = FaviconLoader.shared

    var body: some View {
        Group {
            if let image = loader.icons[host] ?? nil {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: host) { loader.ensure(host) }
    }
}
