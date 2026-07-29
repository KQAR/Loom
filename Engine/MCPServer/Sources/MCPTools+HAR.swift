import Foundation
import LoomSharedModels

/// HAR in both directions: `export_har` (with optional redaction, because a HAR
/// carries live credentials) and `import_har`, which lands foreign flows in the
/// same store so they can be inspected, diffed and replayed like captured ones.
extension MCPToolExecutor {
    func handleExportHAR(_ arguments: [String: Any]) async throws -> String {
        let limit = (arguments["limit"] as? Int) ?? 1000
        // HAR needs full request/response bodies, so hydrate (bodies live in
        // separate storage now); the list/summary tools stay on the body-free path.
        var flows = await engine.recentFlowsForExport(limit: limit)
        if let host = (arguments["host"] as? String), !host.isEmpty {
            let needle = host.lowercased()
            flows = flows.filter { ($0.host ?? "").lowercased().contains(needle) }
        }
        // Redaction runs on the way out, over the flows actually being written — so
        // there is no path where an unredacted flow reaches the file after the caller
        // asked for a redacted export.
        let redaction = try Self.redaction(from: arguments)
        if let redaction { flows = redaction.apply(to: flows) }
        let data = HARExport.encode(flows, appVersion: appVersion)
        // Confine exports to the exports/ directory and take only a basename,
        // so the AI can't overwrite arbitrary user files (~/.zshrc, plists) via
        // a path argument. Any directory component in `filename` is stripped.
        let exportsDir = HandshakeStore.directory.appendingPathComponent("exports", isDirectory: true)
        let filename: String
        if let raw = arguments["filename"] as? String, !raw.isEmpty {
            let base = (raw as NSString).lastPathComponent
            guard !base.isEmpty, base != ".", base != "..", !base.hasPrefix(".") else {
                throw MCPError.invalidParams("invalid filename: \(raw)")
            }
            filename = base.hasSuffix(".har") ? base : base + ".har"
        } else {
            filename = "loom-export.har"
        }
        let url = exportsDir.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw MCPToolFailure("could not write HAR to \(url.path): \(error.localizedDescription)")
        }
        var payload: [String: Any] = ["path": url.path, "entries": flows.count]
        if let redaction {
            // Say what was scrubbed, so a human asked to attach the file knows what it
            // does and doesn't still contain.
            payload["redacted"] = [
                "headers": redaction.headerNames,
                "queryKeys": redaction.queryKeys,
                "bodiesDropped": redaction.dropBodies,
                "webSocketFramesDropped": redaction.dropBodies,
            ] as [String: Any]
            if !redaction.dropBodies {
                // `redact: true` reads as "safe to share now", and it is not: a login
                // POST body or a token in a JSON response survives it untouched. Say
                // so in the result rather than leaving it to whoever remembers the
                // second flag exists.
                payload["warning"] = """
                Bodies and WebSocket frames were NOT redacted — only headers and query \
                parameters were. Pass `redact_bodies: true` as well if this file is \
                leaving the machine.
                """
            }
        }
        return prettyJSON(payload)
    }

    /// Parse the redaction arguments of `export_har`, or nil when the caller didn't
    /// ask for any. Redaction is **opt-in**: a debugging export usually needs the
    /// tokens (that's often the bug), so scrubbing by default would quietly break the
    /// primary use. `redact: false` with explicit header names is an error rather than
    /// a silent no-op — that combination reads as "redact these", and a file that
    /// still holds credentials must never be the result of a misread argument.
    static func redaction(from arguments: [String: Any]) throws -> FlowRedaction? {
        let requested = arguments["redact"] as? Bool
        let extraHeaders = arguments["redact_headers"] as? [String]
        let dropBodies = arguments["redact_bodies"] as? Bool

        if requested == false, extraHeaders?.isEmpty == false || dropBodies == true {
            throw MCPError.invalidParams(
                "`redact: false` contradicts `redact_headers`/`redact_bodies` — omit `redact` or set it to true"
            )
        }
        guard requested == true || extraHeaders?.isEmpty == false || dropBodies == true else { return nil }

        if let extraHeaders, extraHeaders.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw MCPError.invalidParams("`redact_headers` must not contain empty names")
        }
        return FlowRedaction(
            headerNames: FlowRedaction.defaultHeaderNames + (extraHeaders ?? []),
            dropBodies: dropBodies ?? false
        )
    }

    func handleImportHAR(_ arguments: [String: Any]) async throws -> String {
        guard let raw = arguments["path"] as? String, !raw.isEmpty else {
            throw MCPError.invalidParams("`path` must be the path to a .har file")
        }
        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else {
            throw MCPToolFailure("could not read \(url.path)")
        }
        let label = (arguments["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? url.lastPathComponent

        let result: HARImport.Result
        do {
            result = try HARImport.decode(data, label: label)
        } catch HARImport.Failure.notJSON {
            throw MCPToolFailure("\(url.lastPathComponent) is not JSON, so it isn't a HAR file")
        } catch HARImport.Failure.notHAR {
            throw MCPToolFailure("\(url.lastPathComponent) is JSON but has no `log.entries` — not a HAR 1.2 file")
        }
        guard !result.flows.isEmpty else {
            throw MCPToolFailure(
                "no importable entries in \(url.lastPathComponent)"
                + (result.skipped > 0 ? " (\(result.skipped) skipped: \(result.reasons.joined(separator: "; ")))" : "")
            )
        }

        let imported = await engine.importFlows(result.flows)
        var payload: [String: Any] = [
            "imported": imported,
            "importedFrom": label,
            "ids": result.flows.map(\.id.uuidString),
        ]
        // Never a silent partial import: an entry the parser couldn't use is counted
        // and explained, so "12 of 15" can't read as "all of them".
        if result.skipped > 0 {
            payload["skipped"] = result.skipped
            payload["skippedReasons"] = result.reasons
        }
        return prettyJSON(payload)
    }
}
