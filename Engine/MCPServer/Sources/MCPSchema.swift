import Foundation

/// One node of a tool's JSON Schema, as a value the compiler can check.
///
/// The schemas used to be `[String: Any]` literals — 1 100 lines of nested
/// dictionaries whose only reader was `JSONSerialization` on the way out to
/// `tools/list`. That shape had three costs, and they are the same three the
/// render side paid before `MCPRenderModels` replaced hand-built dictionaries with
/// `Encodable` DTOs (§ "A render is a typed value, not a hand-built dictionary"):
///
/// - **Nothing was checked.** A `"tpye"`, a `"required"` holding a key no
///   `properties` declares, a node with `"items"` and no `"type": "array"` — all
///   compiled, and the agent got the malformed schema.
/// - **The `Any` forced escape hatches.** `MCPTool` had to be `@unchecked
///   Sendable` and the shared sub-schemas `nonisolated(unsafe)`, both for the
///   boxed literals rather than for anything actually shared, so the annotations
///   said nothing about what a future edit could break.
/// - **Validation had to re-derive the shape at runtime.** `MCPArgumentValidation`
///   walked the dictionaries with `as?` casts at every step, so a schema node it
///   couldn't decode silently validated nothing.
///
/// The JSON this emits is byte-identical to what the dictionaries produced: this
/// is a refactor of how the schema is *written*, not of the agent-facing surface.
///
/// Deliberately not a general JSON Schema library. It carries exactly the
/// vocabulary Loom's tools use (`type`, `description`, `properties`, `required`,
/// `items`, `enum`, `oneOf`, `additionalProperties`); a node shape that isn't
/// expressible here is one no tool advertises, and adding it should be a
/// deliberate edit here rather than a literal smuggled in from a call site.
struct JSONSchema: Sendable, Equatable {
    enum Kind: String, Sendable {
        case object, string, integer, number, boolean, array
    }

    /// The `type` keyword. Nil only for a bare `oneOf` node, which deliberately
    /// declares no type of its own — the alternatives carry theirs.
    private(set) var kind: Kind?
    private(set) var description: String?
    /// Declared members. **Nil and empty are different schemas**: nil emits no
    /// `properties` key at all, which is how a free-form map (`set_headers`,
    /// `match.query`) says "any key is legal", while `[:]` emits `"properties":
    /// {}`, which is how a no-argument tool says "no key is". Argument validation
    /// reads exactly that distinction, so collapsing them would silently stop
    /// rejecting unknown keys on every tool that takes none.
    private(set) var properties: [String: JSONSchema]?
    private(set) var required: [String] = []
    /// The `enum` keyword — spelled out because `enum` is a Swift keyword and a
    /// backticked property name reads worse than the JSON it produces.
    private(set) var allowedValues: [String]?
    private(set) var oneOf: [JSONSchema] = []
    private(set) var additionalProperties: Bool?

    /// Element schema for an array, held in an array because a struct cannot store
    /// itself by value. Never more than one element; `items` is the accessor.
    private var itemsStorage: [JSONSchema] = []

    var items: JSONSchema? { itemsStorage.first }

    // MARK: - Nodes

    /// An object with declared members. `required` names members that must be
    /// present; it is checked against `properties` in debug builds, because a
    /// required key no schema declares is a demand the agent can never satisfy.
    static func object(
        _ properties: [String: JSONSchema] = [:],
        required: [String] = [],
        description: String? = nil
    ) -> Self {
        assert(
            required.allSatisfy { properties[$0] != nil },
            "required names an undeclared property: \(required.filter { properties[$0] == nil })"
        )
        var schema = Self(kind: .object, description: description)
        schema.properties = properties
        schema.required = required
        return schema
    }

    /// An object with **no declared members**: a free-form string map, where any
    /// key is legal (`set_headers`, `mock_response.headers`, `match.query`).
    static func freeformObject(_ description: String? = nil) -> Self {
        Self(kind: .object, description: description)
    }

    static func string(_ description: String? = nil, allowed: [String]? = nil) -> Self {
        var schema = Self(kind: .string, description: description)
        schema.allowedValues = allowed
        return schema
    }

    static func integer(_ description: String? = nil) -> Self {
        Self(kind: .integer, description: description)
    }

    static func number(_ description: String? = nil) -> Self {
        Self(kind: .number, description: description)
    }

    static func boolean(_ description: String? = nil) -> Self {
        Self(kind: .boolean, description: description)
    }

    static func array(of element: JSONSchema, _ description: String? = nil) -> Self {
        var schema = Self(kind: .array, description: description)
        schema.itemsStorage = [element]
        return schema
    }

    /// A value that may take one of several shapes — a status as either an integer
    /// or a `"5xx"` string, a method as a string or an array of them. Carries no
    /// `type` of its own, matching what the hand-written schemas emitted.
    static func oneOf(_ alternatives: [JSONSchema], description: String? = nil) -> Self {
        var schema = Self(kind: nil, description: description)
        schema.oneOf = alternatives
        return schema
    }

    /// This object plus `extra`. Used where two tools share a vocabulary (the flow
    /// filter, by `get_recent_flows` / `wait_for_flow` / `get_stats`) and one adds
    /// to it, so the shared half stays one definition rather than a copy that
    /// drifts.
    ///
    /// A key already declared is a **programmer error**, not a merge: the dictionary
    /// version of this took `{ current, _ in current }`, which silently kept the
    /// shared entry and dropped the tool's own — so a tool describing `limit`
    /// differently from the filter would have advertised the filter's wording with
    /// nothing to say the tool's text went nowhere.
    func adding(_ extra: [String: JSONSchema], required extraRequired: [String] = []) -> Self {
        var schema = self
        schema.properties = (properties ?? [:]).merging(extra) { current, _ in
            assertionFailure("schema key declared twice; the shared entry would win silently")
            return current
        }
        schema.required = required + extraRequired
        assert(
            schema.required.allSatisfy { schema.properties?[$0] != nil },
            "required names an undeclared property after merge"
        )
        return schema
    }

    // MARK: - JSON

    /// The dictionary `tools/list` serializes. Emits a key only when the schema
    /// carries it, so an absent field stays absent rather than becoming a null or
    /// a default the agent would read as a constraint.
    var json: [String: Any] {
        var out: [String: Any] = [:]
        if let kind { out["type"] = kind.rawValue }
        if let description { out["description"] = description }
        if let properties { out["properties"] = properties.mapValues(\.json) }
        if !required.isEmpty { out["required"] = required }
        if let allowedValues { out["enum"] = allowedValues }
        if !oneOf.isEmpty { out["oneOf"] = oneOf.map(\.json) }
        if let additionalProperties { out["additionalProperties"] = additionalProperties }
        if let items { out["items"] = items.json }
        return out
    }
}
