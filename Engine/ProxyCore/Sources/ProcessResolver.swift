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
    /// A miss may mean "the table predates this connection", which warrants a fresh
    /// scan — but a burst of unresolvable ports must not turn into a scan each. A
    /// table built within this window is treated as authoritative, so miss-driven
    /// scans are bounded by time rather than by connection count.
    private let rescanOnMissAfter: TimeInterval = 0.25
    /// Scans performed — a test seam for "one sweep serves the whole burst".
    private(set) var scanCount = 0

    /// Resolve the app that owns `sourcePort` (its socket's foreign port is
    /// `proxyPort`). Runs a `libproc` scan off the event loop — call it from the
    /// async forwarding task, never on a NIO event loop. Returns nil if the socket
    /// is already gone or the owner can't be determined.
    func resolve(sourcePort: UInt16, proxyPort: UInt16) -> SourceApp? {
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
        if app == nil, !scanned, tableOlderThanLocked(rescanOnMissAfter) {
            // The table predates this connection (it can be up to `tableTTL` old);
            // a just-opened socket deserves one fresh scan before we conclude the
            // owner is unknowable and cache that for `ttl`.
            rebuildTableLocked(proxyPort: proxyPort)
            app = table[sourcePort].map(Self.appInfo(pid:))
        }
        remember(sourcePort: sourcePort, app: app)
        return app
    }

    /// Convenience for the NIO handlers, which hold optional `Int` ports from
    /// `SocketAddress`. Returns nil unless both ports are present and valid.
    ///
    /// `isLoopbackPeer` gates the whole thing: only a connection from this Mac has
    /// a local pid to find. For a LAN device (a phone) the scan could never
    /// succeed — and worse, its *remote* ephemeral port could coincide with some
    /// local process's local port and mis-attribute the phone's traffic to a Mac
    /// app. Skipping is both correct and free.
    static func resolve(sourcePort: Int?, proxyPort: Int?, isLoopbackPeer: Bool) -> SourceApp? {
        guard isLoopbackPeer else { return nil }
        guard let source = sourcePort, let proxy = proxyPort, source > 0, proxy > 0 else { return nil }
        return shared.resolve(
            sourcePort: UInt16(truncatingIfNeeded: source),
            proxyPort: UInt16(truncatingIfNeeded: proxy)
        )
    }

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
        let execPath = n > 0 ? String(cString: buffer) : ""

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
