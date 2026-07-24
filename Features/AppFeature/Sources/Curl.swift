import Foundation
import LoomSharedModels

/// Reconstruct a runnable `curl` for a captured request. A pure helper (not a
/// View method) so the reducer can build it after hydrating the flow's body —
/// the list holds metadata only now, so the copy-as-cURL action fetches the full
/// flow first.
enum Curl {
    /// method, URL, headers (minus ones curl sets itself), and body — single-
    /// quoted with `'\''` escaping, line-continued for readability.
    static func command(_ flow: Flow) -> String {
        let request = flow.request
        var parts: [String] = ["curl"]
        if request.method.uppercased() != "GET" {
            parts.append("-X \(request.method)")
        }
        parts.append("'\(shellEscape(request.url))'")
        for header in request.headers where !omittedHeader(header.name) {
            parts.append("-H '\(shellEscape("\(header.name): \(header.value)"))'")
        }
        if let body = request.body, !body.isEmpty {
            let text = String(data: body, encoding: .utf8) ?? ""
            if !text.isEmpty { parts.append("--data '\(shellEscape(text))'") }
        }
        return parts.joined(separator: " \\\n  ")
    }

    private static func omittedHeader(_ name: String) -> Bool {
        ["content-length", "host"].contains(name.lowercased())
    }

    /// Escape a string for embedding inside single quotes in a POSIX shell.
    private static func shellEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }
}
