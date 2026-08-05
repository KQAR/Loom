import Darwin
import Foundation
import LoomSharedModels

/// Maps a proxied connection back to the local app that made it.
///
/// A client connecting to Loom's proxy shows up as a TCP socket whose *foreign*
/// port is our proxy port and whose *local* port is the client's ephemeral source
/// port. Finding the owner means walking the system's open sockets (`libproc`),
/// which is expensive: every pid, every fd of every pid, one `proc_pidfdinfo` per
/// socket.
///
/// So the walk is done **once per sweep, not once per connection**: a single scan
/// builds the whole `localPort -> pid` table for sockets pointing at the proxy, and
/// every connection in that burst is answered from it. A per-port cache (positive
/// *and* negative) keeps repeat lookups off the scan entirely.
///
/// Resolution only applies to loopback peers — a LAN device has no local pid. See
/// `resolve(sourcePort:proxyPort:)`.
final class ProcessResolver: @unchecked Sendable {
    static let shared = ProcessResolver()

    private let lock = NSLock()
    /// Per-source-port answers, including nil ones (an unresolvable port must not
    /// re-trigger work on every request of a keep-alive connection).
    private var cache: [UInt16: (app: SourceApp?, at: Date)] = [:]
    private let ttl: TimeInterval = 15
    /// Above this many entries, expired ones are swept — the cache is keyed by a
    /// 16-bit port, so it's bounded, but a long session shouldn't hold 65k tuples.
    private let cacheHighWater = 4_096

    /// `localPort -> owning pid` for sockets whose foreign port is the proxy's,
    /// as of `tableBuiltAt`. One scan serves every connection in a burst.
    private var table: [UInt16: pid_t] = [:]
    private var tableBuiltAt: Date?
    private var tableProxyPort: UInt16?
    /// Short: ephemeral ports are recycled, and a table older than this may not
    /// know about a just-opened connection.
    private let tableTTL: TimeInterval = 2
    /// Fallback for callers that don't know when their connection opened: a table
    /// built within this window is treated as authoritative on a miss.
    ///
    /// It used to be the *only* rule, and it was the wrong one. A table cannot
    /// contain a connection that did not exist when it was built, so "the table is
    /// only 0.25 s old" says nothing about a socket opened 0.24 s ago — yet a miss
    /// was cached as a definitive "unknown" for the next 15 s. Under a burst of
    /// short-lived clients (a curl loop, a test runner) that is *every* connection
    /// after the first, and an app-scoped rule evaluated against a nil source app
    /// fails closed: measured 1 match out of 12 identical requests, silently. When
    /// the caller passes `connectionOpenedAt`, that comparison replaces this window.
    private let rescanOnMissAfter: TimeInterval = 0.25
    /// Scans performed — a test seam for "one sweep serves the whole burst".
    private(set) var scanCount = 0

    /// Resolve the app that owns `sourcePort` (its socket's foreign port is
    /// `proxyPort`). Returns nil if the socket is already gone or the owner can't be
    /// determined.
    ///
    /// **Blocking.** Never call this from a NIO event loop, and prefer the async
    /// `resolve(sourcePort:proxyPort:isLoopbackPeer:)` over calling it from a
    /// `Task` — that one moves the sweep off the cooperative pool. This entry point
    /// stays for tests and for callers that already own a suitable thread.
    /// - Parameter connectionOpenedAt: when the client's socket was accepted, if the
    ///   caller knows. A miss is only conclusive when the table was built *after*
    ///   that instant — otherwise the socket simply didn't exist yet to be found,
    ///   and one rescan is what separates "no owner" from "asked too early".
    func resolve(sourcePort: UInt16, proxyPort: UInt16, connectionOpenedAt: Date? = nil) -> SourceApp? {
        lock.lock()
        defer { lock.unlock() }

        if let entry = cache[sourcePort], Date().timeIntervalSince(entry.at) < ttl {
            return entry.app
        }

        var scanned = false
        if isTableStaleLocked(proxyPort: proxyPort) {
            rebuildTableLocked(proxyPort: proxyPort)
            scanned = true
        }
        var app = table[sourcePort].map(Self.appInfo(pid:))
        if app == nil, !scanned, missDeservesRescanLocked(connectionOpenedAt: connectionOpenedAt) {
            rebuildTableLocked(proxyPort: proxyPort)
            app = table[sourcePort].map(Self.appInfo(pid:))
        }
        remember(sourcePort: sourcePort, app: app)
        return app
    }

    /// Whether a miss is worth one more sweep.
    ///
    /// With a known connection time the test is exact and the cost is
    /// self-limiting: a sweep at T answers every connection opened before T, so a
    /// burst arriving together is served by one of them (resolution is serialized
    /// on a single queue, so the second caller already sees the first's table). The
    /// remaining case — connections strictly sequential, each opened after the last
    /// sweep — is one sweep per request at a rate low enough to afford it: a sweep
    /// measures ~3 ms on a normally loaded Mac, not the "tens to hundreds" this
    /// file used to assume.
    private func missDeservesRescanLocked(connectionOpenedAt: Date?) -> Bool {
        guard let openedAt = connectionOpenedAt else {
            return tableOlderThanLocked(rescanOnMissAfter)
        }
        guard let builtAt = tableBuiltAt else { return true }
        return builtAt < openedAt
    }

    /// Convenience for the NIO handlers, which hold optional `Int` ports from
    /// `SocketAddress`. Returns nil unless both ports are present and valid.
    ///
    /// `isLoopbackPeer` gates the whole thing: only a connection from this Mac has
    /// a local pid to find. For a LAN device (a phone) the scan could never
    /// succeed — and worse, its *remote* ephemeral port could coincide with some
    /// local process's local port and mis-attribute the phone's traffic to a Mac
    /// app. Skipping is both correct and free.
    static func resolve(
        sourcePort: Int?, proxyPort: Int?, isLoopbackPeer: Bool, connectionOpenedAt: Date? = nil
    ) -> SourceApp? {
        guard isLoopbackPeer else { return nil }
        guard let source = sourcePort, let proxy = proxyPort, source > 0, proxy > 0 else { return nil }
        return shared.resolve(
            sourcePort: UInt16(truncatingIfNeeded: source),
            proxyPort: UInt16(truncatingIfNeeded: proxy),
            connectionOpenedAt: connectionOpenedAt
        )
    }

    /// The async form the forwarding path uses, and the one new callers should
    /// reach for.
    ///
    /// Being "off the event loop" was never enough. The sweep is *synchronous and
    /// blocking*, so calling it from a bare `Task {}` blocks a worker of the global
    /// cooperative pool — which is sized to core count. With a 2 s table TTL, a
    /// burst of connections produces several concurrent misses, each pinning a
    /// worker for the length of a full pid/fd walk and stalling unrelated async
    /// work process-wide. No data race, so nothing in TSan ever saw it.
    ///
    /// Hopping onto a dedicated serial queue costs one blocked thread instead of
    /// several pool workers. Serial is not a new constraint either: `resolve` holds
    /// one lock for its whole body, so these calls were already serialized — they
    /// just used to serialize while occupying the pool.
    static func resolve(
        sourcePort: Int?, proxyPort: Int?, isLoopbackPeer: Bool, connectionOpenedAt: Date? = nil
    ) async -> SourceApp? {
        guard isLoopbackPeer else { return nil }
        guard let source = sourcePort, let proxy = proxyPort, source > 0, proxy > 0 else { return nil }
        return await withCheckedContinuation { continuation in
            scanQueue.async {
                continuation.resume(returning: shared.resolve(
                    sourcePort: UInt16(truncatingIfNeeded: source),
                    proxyPort: UInt16(truncatingIfNeeded: proxy),
                    connectionOpenedAt: connectionOpenedAt
                ))
            }
        }
    }

    /// Where the blocking sweep actually runs.
    private static let scanQueue = DispatchQueue(label: "com.loom.processresolver.scan")

    // MARK: - Private (lock held)

    private func isTableStaleLocked(proxyPort: UInt16) -> Bool {
        guard tableProxyPort == proxyPort, let builtAt = tableBuiltAt else { return true }
        return Date().timeIntervalSince(builtAt) >= tableTTL
    }

    private func tableOlderThanLocked(_ interval: TimeInterval) -> Bool {
        guard let builtAt = tableBuiltAt else { return true }
        return Date().timeIntervalSince(builtAt) >= interval
    }

    private func rebuildTableLocked(proxyPort: UInt16) {
        scanCount += 1
        table = Self.portTable(proxyPort: proxyPort)
        tableBuiltAt = Date()
        tableProxyPort = proxyPort
    }

    private func remember(sourcePort: UInt16, app: SourceApp?) {
        if cache.count >= cacheHighWater {
            let now = Date()
            cache = cache.filter { now.timeIntervalSince($0.value.at) < ttl }
        }
        cache[sourcePort] = (app, Date())
    }

    // MARK: - libproc socket scan

    /// One sweep of every process's sockets, collecting `localPort -> pid` for the
    /// ones connected to `proxyPort`. Replaces the old per-connection scan that
    /// walked the same data and threw away everything but a single match.
    private static func portTable(proxyPort: UInt16) -> [UInt16: pid_t] {
        let maxPids = 8192
        var pids = [pid_t](repeating: 0, count: maxPids)
        let listSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(maxPids * MemoryLayout<pid_t>.size))
        guard listSize > 0 else { return [:] }
        let pidCount = Int(listSize) / MemoryLayout<pid_t>.size
        let selfPID = getpid()
        var table: [UInt16: pid_t] = [:]

        for i in 0 ..< pidCount {
            let pid = pids[i]
            if pid <= 0 || pid == selfPID { continue }

            let fdsSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            if fdsSize <= 0 { continue }
            let fdCapacity = Int(fdsSize) / MemoryLayout<proc_fdinfo>.size
            if fdCapacity <= 0 { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCapacity)
            let gotSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, fdsSize)
            if gotSize <= 0 { continue }
            let fdCount = Int(gotSize) / MemoryLayout<proc_fdinfo>.size

            for f in 0 ..< fdCount {
                if fds[f].proc_fdtype != UInt32(PROX_FDTYPE_SOCKET) { continue }
                var info = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                let r = proc_pidfdinfo(pid, fds[f].proc_fd, PROC_PIDFDSOCKETINFO, &info, size)
                if r < size { continue }
                if info.psi.soi_kind != Int32(SOCKINFO_TCP) { continue }

                let ini = info.psi.soi_proto.pri_tcp.tcpsi_ini
                let lport = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
                let fport = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport))
                if fport == proxyPort { table[lport] = pid }
            }
        }
        return table
    }

    // MARK: - PID -> app bundle

    /// `bundlePath -> (name, bundle id)`. The mapping is immutable for a given
    /// path, so this is memoized without a TTL — unlike a pid-keyed cache, which
    /// pid reuse would make wrong. `proc_pidpath` still runs per pid (one cheap
    /// syscall); only the `Info.plist` read is skipped.
    private static let bundleLock = NSLock()
    nonisolated(unsafe) private static var bundleInfo: [String: (name: String, bundleID: String?)] = [:]

    private static func appInfo(pid: pid_t) -> SourceApp {
        var buffer = [CChar](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        // Pointer overload, not the array one (deprecated in Swift 6): `proc_pidpath`
        // NUL-terminates, so stopping at the first NUL is still the right read.
        let execPath = n > 0 ? buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : ""

        // Bundled app: derive the enclosing .app and read its Info.plist (Foundation
        // only — no AppKit). e.g. /Applications/Foo.app/Contents/MacOS/Foo -> Foo.app
        if let dotApp = execPath.range(of: ".app/") {
            let bundlePath = String(execPath[..<dotApp.upperBound].dropLast()) // ".../Foo.app"
            let info = bundleDetails(path: bundlePath)
            return SourceApp(name: info.name, bundleID: info.bundleID, bundlePath: bundlePath, pid: pid)
        }

        // CLI tool / daemon: use the executable's basename.
        let name = execPath.isEmpty ? "pid \(pid)" : URL(fileURLWithPath: execPath).lastPathComponent
        return SourceApp(name: name, pid: pid)
    }

    private static func bundleDetails(path: String) -> (name: String, bundleID: String?) {
        bundleLock.lock()
        if let cached = bundleInfo[path] {
            bundleLock.unlock()
            return cached
        }
        bundleLock.unlock()

        let fallbackName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let resolved: (name: String, bundleID: String?)
        if let bundle = Bundle(path: path) {
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? fallbackName
            resolved = (name, bundle.bundleIdentifier)
        } else {
            resolved = (fallbackName, nil)
        }

        bundleLock.lock()
        bundleInfo[path] = resolved
        bundleLock.unlock()
        return resolved
    }
}
