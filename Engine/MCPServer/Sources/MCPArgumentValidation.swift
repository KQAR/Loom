import Foundation

/// Rejects `tools/call` arguments carrying a key no schema declares.
///
/// An ignored argument is not a harmless no-op. `get_recent_flows` with a
/// camel-cased `urlContains` used to return the *unfiltered* ring — 50 flows that
/// read exactly like a filtered answer, so the agent draws a conclusion from the
/// wrong set instead of seeing an error. The same slip inside a write tool's
/// nested object (`setHeaders` under `actions.rewrite_request`) creates a rule
/// that silently doesn't do the one thing it was created to do, and the audit
/// trail records the call as a success. Loom's standing rule is that a fact the
/// engine holds has to reach the operator; "I did not understand this key" is such
/// a fact, and a *silent* one is worse than a loud wrong answer because nothing
/// downstream can tell it happened.
///
/// Scope of the check, and why each edge is where it is:
///
/// - **Only objects that declare `properties`.** A schema node with a bare
///   `"type": "object"` and no `properties` is a deliberate free-form map —
///   `set_headers`, `mock_response.headers`, `match.query` — where any key is
///   legal. Those recurse into nothing and flag nothing.
/// - **Recursive.** The nested objects (`match`, `actions`, `overrides`) are
///   exactly where a typo is hardest to notice, because the enclosing tool still
///   succeeds.
/// - **`_`-prefixed keys pass.** MCP reserves `_meta` (and future underscore
///   members) on any object in the protocol; forbidding them here would reject
///   spec-legal requests.
///
/// This runs at the dispatch choke point, so it applies to every tool without
/// each one re-validating — and it is a JSON-RPC `-32602`, not a tool result with
/// `isError`, because the call was never dispatched (same class as an unknown
/// tool name).
extension MCPToolExecutor {
    /// Throws `MCPError.invalidParams` naming the first argument the tool's schema
    /// doesn't declare. Reports one at a time: the caller's fix is per-key, and a
    /// list of every mistake in a hand-written call is rarely what unblocks them.
    static func validateArguments(_ arguments: [String: Any], against tool: MCPTool) throws {
        guard let unknown = firstUnknownArgument(in: arguments, schema: tool.inputSchema, path: "") else { return }
        throw MCPError.invalidParams(unknown.message(tool: tool.name))
    }

    /// One rejected key: where it appeared, and what was legal there.
    struct UnknownArgument {
        /// Dotted path from the arguments root, e.g. `actions.rewrite_request.setHeaders`.
        let path: String
        let declared: [String]

        var leaf: String {
            guard let last = path.split(separator: ".").last else { return path }
            return String(last)
        }

        func message(tool: String) -> String {
            var text = "unknown argument \"\(path)\" for \(tool)"
            // The overwhelmingly common cause is a case/separator slip on a real
            // key (`urlContains` for `url_contains`), so naming the intended key
            // beats making the caller diff the list themselves.
            if let suggestion = Self.closestMatch(to: leaf, among: declared) {
                text += " — did you mean \"\(suggestion)\"?"
            }
            text += declared.isEmpty
                ? ". This tool takes no arguments."
                : ". Accepted here: \(declared.joined(separator: ", "))."
            return text
        }

        /// A declared key that differs only in case or separators. Deliberately not
        /// an edit-distance search: `status_min` vs `status_max` are one character
        /// apart and suggesting one for the other would be actively misleading.
        static func closestMatch(to key: String, among declared: [String]) -> String? {
            let target = normalized(key)
            guard !target.isEmpty else { return nil }
            return declared.first { normalized($0) == target }
        }

        private static func normalized(_ key: String) -> String {
            key.lowercased().filter { $0 != "_" && $0 != "-" }
        }
    }

    private static func firstUnknownArgument(
        in object: [String: Any], schema: [String: Any], path: String
    ) -> UnknownArgument? {
        // No `properties` → a free-form map (or an unschema'd blob). Every key is
        // legal and there is nothing below to walk.
        guard let properties = schema["properties"] as? [String: Any] else { return nil }
        let declared = properties.keys.sorted()
        // An object that explicitly opts into extras keeps them; its declared
        // children are still checked.
        let allowsExtras = schema["additionalProperties"] as? Bool == true

        // Sorted so the reported key is stable across runs rather than whichever
        // one the dictionary happened to hash first.
        for key in object.keys.sorted() {
            // MCP reserves `_`-prefixed members protocol-wide.
            if key.hasPrefix("_") { continue }
            guard let childSchema = properties[key] as? [String: Any] else {
                if allowsExtras { continue }
                return UnknownArgument(path: child(of: path, key), declared: declared)
            }
            guard let value = object[key],
                  let nested = firstUnknownArgument(in: value, schema: childSchema, path: child(of: path, key))
            else { continue }
            return nested
        }
        return nil
    }

    /// Walk a value of any shape against its schema node: objects recurse, arrays
    /// recurse per element through `items`, scalars have nothing to check.
    private static func firstUnknownArgument(
        in value: Any, schema: [String: Any], path: String
    ) -> UnknownArgument? {
        if let object = value as? [String: Any] {
            return firstUnknownArgument(in: object, schema: schema, path: path)
        }
        if let array = value as? [Any], let items = schema["items"] as? [String: Any] {
            for (index, element) in array.enumerated() {
                if let unknown = firstUnknownArgument(in: element, schema: items, path: "\(path)[\(index)]") {
                    return unknown
                }
            }
        }
        return nil
    }

    private static func child(of path: String, _ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }
}
