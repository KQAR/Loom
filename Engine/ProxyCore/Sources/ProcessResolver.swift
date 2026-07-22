import Darwin
import Foundation
import SharedModels

/// Maps a proxied connection back to the local app that made it.
///
/// A client connecting to Loom's proxy shows up as a TCP socket whose *foreign*
/// port is our proxy port and whose *local* port is the client's ephemeral source
/// port. We scan the system's open sockets (`libproc`) for the one matching
/// `(local == sourcePort, foreign == proxyPort)`, take its owning PID, and resolve
/// that PID to an app bundle (name / bundle id / .app path) — no AppKit, so this
/// stays usable from the engine layer. The icon is derived in the UI from `bundlePath`.
///
/// Results are cached by source port (with a short TTL) so keep-alive connections
/// and repeated lookups don't rescan; a nil result is cached too, so unresolvable
/// ports aren't retried on every request.
final class ProcessResolver: @unchecked Sendable {
    static let shared = ProcessResolver()

    private let lock = NSLock()
    private var cache: [UInt16: (app: SourceApp?, at: Date)] = [:]
    private let ttl: TimeInterval = 15

    /// Resolve the app that owns `sourcePort` (its socket's foreign port is
    /// `proxyPort`). Runs a `libproc` scan off the event loop — call it from the
    /// async forwarding task, never on a NIO event loop. Returns nil if the socket
    /// is already gone or the owner can't be determined.
    func resolve(sourcePort: UInt16, proxyPort: UInt16) -> SourceApp? {
        lock.lock()
        if let entry = cache[sourcePort], Date().timeIntervalSince(entry.at) < ttl {
            lock.unlock()
            return entry.app
        }
        lock.unlock()

        let app = pidOwningSocket(localPort: sourcePort, foreignPort: proxyPort).map(appInfo(pid:))

        lock.lock()
        cache[sourcePort] = (app, Date())
        lock.unlock()
        return app
    }

    /// Convenience for the NIO handlers, which hold optional `Int` ports from
    /// `SocketAddress`. Returns nil unless both ports are present and valid.
    static func resolve(sourcePort: Int?, proxyPort: Int?) -> SourceApp? {
        guard let source = sourcePort, let proxy = proxyPort, source > 0, proxy > 0 else { return nil }
        return shared.resolve(
            sourcePort: UInt16(truncatingIfNeeded: source),
            proxyPort: UInt16(truncatingIfNeeded: proxy)
        )
    }

    // MARK: - libproc socket scan

    private func pidOwningSocket(localPort: UInt16, foreignPort: UInt16) -> pid_t? {
        let maxPids = 8192
        var pids = [pid_t](repeating: 0, count: maxPids)
        let listSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(maxPids * MemoryLayout<pid_t>.size))
        guard listSize > 0 else { return nil }
        let pidCount = Int(listSize) / MemoryLayout<pid_t>.size
        let selfPID = getpid()

        for i in 0..<pidCount {
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

            for f in 0..<fdCount {
                if fds[f].proc_fdtype != UInt32(PROX_FDTYPE_SOCKET) { continue }
                var info = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                let r = proc_pidfdinfo(pid, fds[f].proc_fd, PROC_PIDFDSOCKETINFO, &info, size)
                if r < size { continue }
                if info.psi.soi_kind != Int32(SOCKINFO_TCP) { continue }

                let ini = info.psi.soi_proto.pri_tcp.tcpsi_ini
                let lport = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
                let fport = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport))
                if lport == localPort && fport == foreignPort {
                    return pid
                }
            }
        }
        return nil
    }

    // MARK: - PID -> app bundle

    private func appInfo(pid: pid_t) -> SourceApp {
        var buffer = [CChar](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let execPath = n > 0 ? String(cString: buffer) : ""

        // Bundled app: derive the enclosing .app and read its Info.plist (Foundation
        // only — no AppKit). e.g. /Applications/Foo.app/Contents/MacOS/Foo -> Foo.app
        if let dotApp = execPath.range(of: ".app/") {
            let bundlePath = String(execPath[..<dotApp.upperBound].dropLast()) // ".../Foo.app"
            let fallbackName = URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
            if let bundle = Bundle(path: bundlePath) {
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? fallbackName
                return SourceApp(name: name, bundleID: bundle.bundleIdentifier, bundlePath: bundlePath, pid: pid)
            }
            return SourceApp(name: fallbackName, bundlePath: bundlePath, pid: pid)
        }

        // CLI tool / daemon: use the executable's basename.
        let name = execPath.isEmpty ? "pid \(pid)" : URL(fileURLWithPath: execPath).lastPathComponent
        return SourceApp(name: name, pid: pid)
    }
}
