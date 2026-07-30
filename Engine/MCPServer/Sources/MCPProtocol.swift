import Foundation

/// Which MCP revision a request is speaking, and whether it is well-formed for that
/// revision. Kept out of `MCPServer.swift` because Loom serves **two eras at once**
/// and the rules for telling them apart are the fiddliest part of the transport:
///
/// - **modern** (`2026-07-28`) carries the protocol version, client identity and
///   client capabilities as per-request `_meta`, and there is no handshake. The
///   version is also mirrored into HTTP headers, which the server must check against
///   the body — a gateway routing on the header while the server executes the body is
///   exactly the split-brain the spec's `HeaderMismatch` exists to prevent.
/// - **legacy** (`2025-06-18`) establishes a session with `initialize`. Loom has no
///   session state to begin with, so serving it is just "answer `initialize`, then
///   behave as before".
///
/// Dual-era matters because the fallback only works in one direction: a legacy client
/// has no way to *fall forward*. If Loom answered only modern, every client that
/// hasn't rolled over yet — including Claude Code and Cursor until they do — would
/// simply stop connecting. A modern client, by contrast, probes and falls back.
enum MCPProtocol {
    /// Newest revision Loom speaks. Advertised first everywhere.
    static let latest = "2026-07-28"

    /// Newest handshake-based revision Loom speaks, and what an `initialize` asking
    /// for something unknown is answered with.
    static let latestLegacy = "2025-06-18"

    /// Every revision Loom serves, newest first. This is what `server/discover`
    /// reports and what an `UnsupportedProtocolVersionError` offers the client to
    /// retry with — so it must be the honest set, not an aspiration.
    static let supported = [latest, latestLegacy]

    /// Revisions that convey version/identity/capabilities per request rather than
    /// through `initialize`. A one-element set today; a `Set` because the next
    /// modern revision joins it rather than replacing the check.
    static let modern: Set<String> = [latest]

    /// Reserved `_meta` keys. The `io.modelcontextprotocol/` prefix is reserved by
    /// the spec, so these are exact strings, not a naming convention we chose.
    enum MetaKey {
        static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
        static let clientInfo = "io.modelcontextprotocol/clientInfo"
        static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
        static let serverInfo = "io.modelcontextprotocol/serverInfo"
    }

    /// How long a client may consider `tools/list` fresh.
    ///
    /// Loom's tool registry is compiled in — it cannot change while the app runs, and
    /// `listChanged` is `false` — so this could be hours. It deliberately isn't: the
    /// list *does* change across an app update, and a client holding an hour-old cache
    /// would keep calling a tool that no longer exists. Five minutes (the spec's own
    /// example for `tools/list`) bounds that window to something an agent session can
    /// ride out, while still removing the per-turn re-list that dominates a client's
    /// base tool overhead.
    static let listTTLMs = 300_000

    /// `tools/list` holds no per-caller data — same registry for every client — so a
    /// shared cache may serve it to anyone.
    static let listCacheScope = "public"

    /// Which era a request is speaking.
    ///
    /// Decided from the **body** first, because that is what the server actually
    /// executes. `_meta` protocol version present → modern; `initialize` → legacy;
    /// otherwise a bare request, which is legacy (a legacy client's `tools/list`
    /// carries no `_meta`). The header is consulted only to catch the one remaining
    /// case: a header claiming a modern revision over a body that has no `_meta` at
    /// all. That is a genuine mismatch and must be reported as one rather than
    /// quietly served under legacy rules — a client told "modern" by a gateway and
    /// "legacy" by us is how the two disagree about what ran.
    static func era(method: String, meta: [String: Any], headerVersion: String?) -> Era {
        if meta[MetaKey.protocolVersion] != nil { return .modern }
        if method == "initialize" { return .legacy }
        if let headerVersion, modern.contains(headerVersion) { return .modern }
        return .legacy
    }

    enum Era {
        case modern
        case legacy
    }

    /// Validate a modern request's `_meta` and its header/body agreement.
    ///
    /// Order is deliberate and is the order a client can act on:
    ///
    /// 1. the declared version, so a client on the wrong revision is told to
    ///    renegotiate before being told its headers are wrong for a revision it
    ///    wasn't speaking anyway;
    /// 2. the required `_meta` fields;
    /// 3. header ↔ body agreement.
    ///
    /// `clientInfo` is *not* required (the spec marks it SHOULD), and Loom needs no
    /// client capability to answer anything, so `MissingRequiredClientCapability`
    /// (`-32021`) is never emitted — every tool here reads or writes the local proxy
    /// and asks nothing of the client.
    static func validateModern(
        method: String,
        params: [String: Any],
        meta: [String: Any],
        headers: MCPRequestHeaders
    ) throws {
        guard let declared = meta[MetaKey.protocolVersion] as? String else {
            throw MCPError.headerMismatch(
                "MCP-Protocol-Version declares \(headers.protocolVersion ?? "a modern revision") "
                    + "but the body carries no \(MetaKey.protocolVersion)"
            )
        }
        guard modern.contains(declared) else {
            throw MCPError.unsupportedProtocolVersion(requested: declared)
        }
        guard meta[MetaKey.clientCapabilities] != nil else {
            throw MCPError.invalidParams("missing required _meta field \(MetaKey.clientCapabilities)")
        }
        guard headers.protocolVersion == declared else {
            throw MCPError.headerMismatch(
                "MCP-Protocol-Version is \(headers.protocolVersion.map { "'\($0)'" } ?? "absent") "
                    + "but the body declares '\(declared)'"
            )
        }
        guard headers.method == method else {
            throw MCPError.headerMismatch(
                "Mcp-Method is \(headers.method.map { "'\($0)'" } ?? "absent") "
                    + "but the body method is '\(method)'"
            )
        }
        // `Mcp-Name` mirrors `params.name` and is required for `tools/call`. Loom
        // exposes no resources or prompts, so the `params.uri` half doesn't arise.
        guard method == "tools/call" else { return }
        let bodyName = params["name"] as? String
        guard let headerName = headers.name.map(decodeHeaderValue) else {
            throw MCPError.headerMismatch("Mcp-Name is required for tools/call and is absent")
        }
        guard headerName == bodyName else {
            throw MCPError.headerMismatch(
                "Mcp-Name is '\(headerName)' but the body name is \(bodyName.map { "'\($0)'" } ?? "absent")"
            )
        }
    }

    /// Decode the spec's Base64 sentinel, `=?base64?<payload>?=`, used for a header
    /// value that can't be carried as plain ASCII. Must run **before** comparing a
    /// mirrored header to its body value, or an encoded name never matches. A payload
    /// that isn't valid Base64/UTF-8 is returned untouched so the comparison fails
    /// with a header-mismatch rather than being silently accepted as something else.
    static func decodeHeaderValue(_ value: String) -> String {
        let prefix = "=?base64?", suffix = "?="
        guard value.hasPrefix(prefix), value.hasSuffix(suffix),
              value.count >= prefix.count + suffix.count
        else { return value }
        let payload = String(value.dropFirst(prefix.count).dropLast(suffix.count))
        guard let data = Data(base64Encoded: payload),
              let decoded = String(data: data, encoding: .utf8)
        else { return value }
        return decoded
    }
}

/// The HTTP headers the modern transport mirrors from the body, lifted off the
/// request so the dispatcher stays independent of NIO.
struct MCPRequestHeaders {
    let protocolVersion: String?
    let method: String?
    let name: String?

    static let none = MCPRequestHeaders(protocolVersion: nil, method: nil, name: nil)
}

/// A dispatched reply: JSON-RPC bytes plus the HTTP status to send them with.
///
/// The status is part of the protocol in the modern era — `400` for a validation
/// failure, `404` for an unknown method — and a client uses it to decide whether to
/// fall back. The legacy era keeps returning `200` for everything including errors,
/// which is what clients on `2025-06-18` have always been served here; changing that
/// under them buys nothing and risks a client that reads the status before the body.
struct MCPHTTPReply {
    let statusCode: Int
    let body: Data
}
