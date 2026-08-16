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
    ///
    /// Takes Foundation's `[String: Any]` because that is what `JSONSerialization`
    /// produced one layer up, and converts it **here, once**: everything past this
    /// line — validation, the handlers, the audit rendering — works on `JSONValue`,
    /// so the whole tool surface is checked `Sendable` and no handler casts an `Any`
    /// again (see `MCPJSONValue.swift` for why the boundary is drawn here).
    func call(name: String, arguments rawArguments: [String: Any]) async throws -> String {
        try await call(name: name, arguments: JSONValue.object(fromJSON: rawArguments))
    }

    func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        guard let tool = Self.toolsByName[name] else {
            throw MCPError.unknownTool(name)
        }
        // Before the handler, and before any audit entry: an argument the schema
        // doesn't declare means the call as written was never understood, so
        // running it would answer a different question than the one asked (see
        // `MCPArgumentValidation`). Nothing touched real traffic, so this is a
        // dispatch refusal like an unknown tool name, not an audited failure.
        try Self.validateArguments(arguments, against: tool)
        let parsed = MCPArguments(tool: name, values: arguments, schema: tool.inputSchema)
        let handler = tool.handler
        // Read tools run straight through. Write tools are the whole reason Loom
        // exists — record each in the audit trail (success or failure) so the
        // supervising human can see what the agent did to real traffic.
        guard tool.isWrite else {
            return try await handler(self, parsed)
        }
        let renderedArgs = AuditEntry.truncate(Self.auditArguments(arguments))
        do {
            let result = try await handler(self, parsed)
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

    /// Render a tool's arguments as compact JSON for the audit trail. Truncation is
    /// applied by the caller (whole-string, so we don't split a key from its value).
    static func auditArguments(_ arguments: [String: JSONValue]) -> String {
        guard !arguments.isEmpty else { return "{}" }
        let object = redactingSecrets(arguments).mapValues(\.json)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return String(describing: object) }
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
    /// Kept in step with the advertised schema by `AuditRedactionCensusTests`, which
    /// fails on any tool property whose *name* reads like a credential and is neither
    /// listed here nor recorded there with the reason it is safe. A list of secrets
    /// maintained by remembering is a list that leaks the next one.
    static let redactedArgumentNames: Set<String> = ["pkcs12_base64", "passphrase"]

    /// Redaction is **by key at any depth**, not just at the top level.
    ///
    /// Every argument carrying key material today is a top-level property of
    /// `set_client_certificate`, so a flat pass was correct — and correct only for as
    /// long as that stayed true. A tool that grouped its inputs (`identity: {…}`), or
    /// a free-form map an agent happened to put a `passphrase` key in, would have
    /// written the value into `audit.sqlite` verbatim. The trail is durable, on disk,
    /// and readable by anyone with the file; the cost of walking the tree is a
    /// recursion over an argument object that has already been parsed once.
    private static func redactingSecrets(_ arguments: [String: JSONValue]) -> [String: JSONValue] {
        arguments.reduce(into: [:]) { result, pair in
            result[pair.key] = redactedArgumentNames.contains(pair.key)
                ? .string("<redacted>")
                : redactingSecrets(pair.value)
        }
    }

    private static func redactingSecrets(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .object(members): .object(redactingSecrets(members))
        case let .array(elements): .array(elements.map(redactingSecrets))
        case .string, .int, .double, .bool, .null: value
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
