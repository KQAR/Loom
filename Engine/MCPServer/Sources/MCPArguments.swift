import Foundation

/// One `tools/call`'s arguments, read against the schema that advertised them.
///
/// Handlers used to take the raw `[String: Any]` and reach into it with `as?`
/// casts, which cost three things — each of which was a real defect, not a
/// tidiness argument:
///
/// - **A wrong-typed value read as absent.** `(arguments["only_errors"] as? Bool)
///   ?? false` turns `"true"` into `false`, and `arguments["limit"] as? Int` turns
///   a JSON `20.0` into the default 20. Both are the failure
///   `MCPArgumentValidation` exists to prevent one layer up: a filter that
///   silently doesn't apply hands back traffic the agent believes was filtered.
///   Every accessor here throws `invalidParams` naming the key and what it
///   expected instead.
/// - **Numeric spelling handled per call site.** `since_seconds` accepted an `Int`
///   or a `Double`; every other number took whichever cast its author wrote. JSON
///   has one number type, so this reads integers and doubles interchangeably —
///   `int` rejects a fractional value rather than truncating it, which is the one
///   case where guessing would change the caller's meaning.
/// - **No check that a handler reads what the tool advertises.** The schema is the
///   only thing an agent sees, so a handler reading a key no schema declares is
///   dead code the agent can never reach — and `validateArguments` *rejects* that
///   key at the choke point, so the accommodation actively misleads. That was live:
///   `resume` read `id` as an alias for `pending_id`, its description promised
///   "either argument name works", and the call was refused before the handler ran.
///   Reading an undeclared key now trips an assertion in debug builds and in every
///   test run, which is how that one was found.
///
/// Nested objects come back as `MCPArguments` carrying the child schema, so the
/// checks continue all the way down; a free-form map (`set_headers`, `match.query`)
/// has no declared keys and is read with `stringMap` / `rawObject` instead.
struct MCPArguments: Sendable {
    /// Tool name, for error messages — the agent gets "…for get_recent_flows"
    /// rather than a bare key.
    let tool: String
    /// The arguments as sent, converted off Foundation's `Any` at the boundary.
    let values: [String: JSONValue]
    /// The node that declared these arguments. Nil for a free-form map, where any
    /// key is legal and there is nothing to check against.
    private let declared: [String: JSONSchema]?
    /// Dotted path for a nested object, so an error names `actions.map_local.path`.
    private let path: String

    init(tool: String, values: [String: JSONValue], schema: JSONSchema, path: String = "") {
        self.tool = tool
        self.values = values
        declared = schema.properties
        self.path = path
    }

    /// The arguments of a named tool, read against that tool's own schema — what
    /// `call` builds, and what a caller exercising one parser in isolation (a test,
    /// or a handler helper) needs so the declared-key check still applies. An unknown
    /// name gets a free-form node rather than a crash: the dispatcher has already
    /// rejected that call, and this is the reading side.
    static func forTool(_ name: String, _ values: [String: JSONValue]) -> MCPArguments {
        MCPArguments(
            tool: name,
            values: values,
            schema: MCPToolExecutor.toolsByName[name]?.inputSchema ?? .freeformObject()
        )
    }

    // MARK: - Presence

    /// Whether the key was sent at all. The distinction matters for the update
    /// tools, where "absent" means leave it alone and a present value replaces.
    func has(_ key: String) -> Bool {
        presentValue(key) != nil
    }

    var isEmpty: Bool { values.isEmpty }

    /// The parsed value, for the two arguments whose schema is a `oneOf` and so have
    /// no single Swift type (`method`, `status`). Still checked for being declared.
    func value(_ key: String) -> JSONValue? {
        presentValue(key)
    }

    // MARK: - Scalars

    func string(_ key: String) throws -> String? {
        guard let value = presentValue(key) else { return nil }
        guard case let .string(text) = value else { throw wrongType(key, "a string") }
        return text
    }

    func string(_ key: String, or fallback: String) throws -> String {
        try string(key) ?? fallback
    }

    /// A required string: absent and wrong-typed are the same answer to the caller
    /// ("send me one"), so they share a message that says what it is for.
    func requiredString(_ key: String, _ what: String) throws -> String {
        guard let text = try string(key) else {
            throw MCPError.invalidParams("`\(display(key))` must be \(what)")
        }
        return text
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = presentValue(key) else { return nil }
        guard case let .bool(flag) = value else { throw wrongType(key, "true or false") }
        return flag
    }

    func bool(_ key: String, or fallback: Bool) throws -> Bool {
        try bool(key) ?? fallback
    }

    func requiredBool(_ key: String) throws -> Bool {
        guard let flag = try bool(key) else {
            throw MCPError.invalidParams("`\(display(key))` must be a boolean")
        }
        return flag
    }

    /// An integer, accepting the `20.0` spelling a JSON encoder may produce. A
    /// genuinely fractional number is rejected: truncating `2.5` to `2` would answer
    /// a question the caller didn't ask.
    func int(_ key: String) throws -> Int? {
        guard let value = presentValue(key) else { return nil }
        switch value {
        case let .int(exact):
            return exact
        case let .double(number):
            guard number.truncatingRemainder(dividingBy: 1) == 0, number.magnitude < Double(Int.max) else {
                throw wrongType(key, "a whole number")
            }
            return Int(number)
        default:
            throw wrongType(key, "a number")
        }
    }

    func int(_ key: String, or fallback: Int) throws -> Int {
        try int(key) ?? fallback
    }

    func double(_ key: String) throws -> Double? {
        guard let value = presentValue(key) else { return nil }
        switch value {
        case let .double(number): return number
        case let .int(exact): return Double(exact)
        default: throw wrongType(key, "a number")
        }
    }

    func double(_ key: String, or fallback: Double) throws -> Double {
        try double(key) ?? fallback
    }

    /// A UUID-shaped string. One message for "not a string" and "not a UUID",
    /// because the fix is the same: send the id a list tool handed you.
    func uuid(_ key: String) throws -> UUID? {
        guard let text = try string(key) else { return nil }
        guard let id = UUID(uuidString: text) else {
            throw MCPError.invalidParams("`\(display(key))` must be a UUID string")
        }
        return id
    }

    func requiredUUID(_ key: String, _ what: String) throws -> UUID {
        let text = try requiredString(key, what)
        guard let id = UUID(uuidString: text) else {
            throw MCPError.invalidParams("`\(display(key))` must be \(what)")
        }
        return id
    }

    /// A value from a fixed set, mapped through its `RawRepresentable` type.
    /// Rejects an unknown value rather than falling back to a default — a typo that
    /// quietly widens a filter returns the noise the filter existed to remove.
    func option<T: RawRepresentable & CaseIterable>(
        _ key: String, _ type: T.Type
    ) throws -> T? where T.RawValue == String {
        guard let text = try string(key) else { return nil }
        guard let value = T(rawValue: text.lowercased()) else {
            let allowed = T.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            throw MCPError.invalidParams("`\(display(key))` must be one of \(allowed)")
        }
        return value
    }

    func option<T: RawRepresentable & CaseIterable>(
        _ key: String, or fallback: T
    ) throws -> T where T.RawValue == String {
        try option(key, T.self) ?? fallback
    }

    // MARK: - Collections

    func stringArray(_ key: String) throws -> [String]? {
        guard let value = presentValue(key) else { return nil }
        guard case let .array(elements) = value else { throw wrongType(key, "an array of strings") }
        return try elements.map {
            guard case let .string(text) = $0 else { throw wrongType(key, "an array of strings") }
            return text
        }
    }

    /// A free-form map of names to values, as the header arguments take. Values are
    /// stringified rather than rejected: a `Content-Length: 12` sent as a number is
    /// a header either way, and refusing it would be pedantry the agent has to
    /// discover.
    func stringMap(_ key: String) throws -> [String: String]? {
        guard let object = try rawObject(key) else { return nil }
        return object.mapValues { value in
            switch value {
            case let .string(text): text
            case let .bool(flag): flag ? "true" : "false"
            case let .int(number): String(number)
            case let .double(number): String(number)
            default: String(describing: value.json)
            }
        }
    }

    /// The map as parsed, for the free-form objects whose values are not strings
    /// (`match.query`, whose entries may themselves be objects).
    func rawObject(_ key: String) throws -> [String: JSONValue]? {
        guard let value = presentValue(key) else { return nil }
        guard case let .object(object) = value else { throw wrongType(key, "an object") }
        return object
    }

    /// A nested object, read against its own schema node so undeclared keys and
    /// wrong types are caught at every depth.
    func object(_ key: String) throws -> MCPArguments? {
        guard let object = try rawObject(key) else { return nil }
        return MCPArguments(
            tool: tool, values: object, schema: childSchema(key), path: display(key)
        )
    }

    /// An array of nested objects (the substitution lists).
    func objects(_ key: String) throws -> [MCPArguments]? {
        guard let value = presentValue(key) else { return nil }
        guard case let .array(elements) = value else { throw wrongType(key, "an array of objects") }
        let element = childSchema(key).items ?? .freeformObject()
        return try elements.enumerated().map { index, raw in
            guard case let .object(object) = raw else { throw wrongType(key, "an array of objects") }
            return MCPArguments(
                tool: tool, values: object, schema: element, path: "\(display(key))[\(index)]"
            )
        }
    }

    // MARK: - Internals

    private func presentValue(_ key: String) -> JSONValue? {
        checkDeclared(key)
        guard let value = values[key], value != .null else { return nil }
        return value
    }

    /// A read of a key the tool never advertised. Fatal in debug (so it surfaces in
    /// the test run rather than in a session), tolerated in release — a handler that
    /// reads a stray key does no harm at runtime, and `validateArguments` has
    /// already refused the call if a client actually sent it.
    private func checkDeclared(_ key: String) {
        guard let declared, declared[key] == nil else { return }
        assertionFailure(
            "\(tool) reads \"\(display(key))\", which its schema does not declare — "
                + "a client sending it is refused by validateArguments, so this read can never fire"
        )
    }

    private func childSchema(_ key: String) -> JSONSchema {
        declared?[key] ?? .freeformObject()
    }

    private func display(_ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    private func wrongType(_ key: String, _ expected: String) -> MCPError {
        .invalidParams("`\(display(key))` must be \(expected) (in \(tool))")
    }
}
