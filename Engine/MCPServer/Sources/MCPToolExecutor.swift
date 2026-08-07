import Foundation
import LoomSharedModels

/// Dispatches MCP `tools/call` requests to the proxy engine and renders results.
/// Read tools inspect captured traffic; `replay_flow` is the write tool that
/// makes Loom "AI-operable" rather than merely AI-readable.
///
/// The tool surface is split by domain across `MCPToolSchemas` (what is
/// advertised) and `MCPTools+*` (what each tool does). This file holds only the
/// executor's state and the dispatch choke point — including the audit recording
/// that every write tool goes through.
struct MCPToolExecutor {
    let engine: ProxyControlling
    let appVersion: String
    let protocolVersion: String

    /// Injected by the app; nil where system-proxy control isn't available (an
    /// embedder driving the engine as a library, or a test).
    var routing: SystemRoutingControlling?

    /// The era tally `get_version` reads back. Nil for an executor built without a
    /// server around it (every test that exercises a tool directly), in which case
    /// `get_version` omits the block rather than reporting zeros — "nothing counted"
    /// and "nothing was counting" are different answers.
    var eraLog: MCPEraLog?

    /// Name → tool, indexed from the one table in `MCPToolSchemas`. Dispatch is a
    /// lookup, not a growing switch — and no longer a second list to keep in step
    /// with the advertised one, because both come from the same values.
    static let toolsByName: [String: MCPTool] = Dictionary(
        tools.map { ($0.name, $0) },
        // Two tools sharing a name is a programmer error, not a merge: the first
        // would shadow the second's handler while both stayed advertised.
        uniquingKeysWith: { first, _ in
            assertionFailure("duplicate MCP tool name \"\(first.name)\"")
            return first
        }
    )

    /// Tools that touch real traffic — every one is audited (§ `call`). Derived
    /// from `MCPTool.isWrite` rather than maintained as a parallel set, so a new
    /// write tool cannot be advertised and dispatched while quietly escaping the
    /// audit trail. Still a flag rather than a search for the "This is a write
    /// action." marker: a typo in prose must not be able to switch auditing off.
    static let writeTools: Set<String> = Set(tools.lazy.filter(\.isWrite).map(\.name))

    /// Dispatch one `tools/call`. Returns the tool's text result, or throws a
    /// `MCPError` describing why the call could not be dispatched.
    func call(name: String, arguments: [String: Any]) async throws -> String {
        guard let tool = Self.toolsByName[name] else {
            throw MCPError.unknownTool(name)
        }
        // Before the handler, and before any audit entry: an argument the schema
        // doesn't declare means the call as written was never understood, so
        // running it would answer a different question than the one asked (see
        // `MCPArgumentValidation`). Nothing touched real traffic, so this is a
        // dispatch refusal like an unknown tool name, not an audited failure.
        try Self.validateArguments(arguments, against: tool)
        let handler = tool.handler
        // Read tools run straight through. Write tools are the whole reason Loom
        // exists — record each in the audit trail (success or failure) so the
        // supervising human can see what the agent did to real traffic.
        guard tool.isWrite else {
            return try await handler(self, arguments)
        }
        let renderedArgs = AuditEntry.truncate(Self.auditArguments(arguments))
        do {
            let result = try await handler(self, arguments)
            await engine.recordAudit(AuditEntry(
                tool: name, succeeded: true,
                arguments: renderedArgs, detail: AuditEntry.truncate(result)
            ))
            return result
        } catch {
            let message: String
            switch error {
            case let failure as MCPToolFailure: message = failure.message
            case let mcp as MCPError: message = mcp.message
            default: message = error.localizedDescription
            }
            await engine.recordAudit(AuditEntry(
                tool: name, succeeded: false,
                arguments: renderedArgs, detail: AuditEntry.truncate(message)
            ))
            throw error
        }
    }

    /// Render a tool's arguments as compact JSON for the audit trail. Falls back
    /// to `String(describing:)` for the rare non-JSON value. Truncation is applied
    /// by the caller (whole-string, so we don't split a key from its value).
    static func auditArguments(_ arguments: [String: Any]) -> String {
        guard !arguments.isEmpty else { return "{}" }
        let arguments = redactingSecrets(arguments)
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return String(describing: arguments) }
        return string
    }

    /// Argument names whose *values* must never reach the audit trail.
    ///
    /// The trail is durable, on-disk and readable by anyone with the file, and it
    /// exists to record what an agent did — not to archive the credentials it was
    /// handed. `set_client_certificate` carries a PKCS#12 bundle (a private key) and
    /// its passphrase; auditing those verbatim would turn the supervision feature
    /// into a second copy of the operator's key material. The argument *name* still
    /// appears, so "a certificate was installed for this host" stays visible, which
    /// is the part supervision needs.
    static let redactedArgumentNames: Set<String> = ["pkcs12_base64", "passphrase"]

    private static func redactingSecrets(_ arguments: [String: Any]) -> [String: Any] {
        guard arguments.keys.contains(where: redactedArgumentNames.contains) else { return arguments }
        return arguments.mapValues { $0 }.reduce(into: [:]) { result, pair in
            result[pair.key] = redactedArgumentNames.contains(pair.key) ? "<redacted>" : pair.value
        }
    }

    func prettyJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return String(describing: value)
        }
        return string
    }
}
