import Foundation
import Testing
@testable import MCPServer

/// The reusable half of an input-schema census: model fields in, advertised schema
/// properties out, and the comparison between them.
///
/// ## Why this is shared rather than one suite's plumbing
///
/// `RuleCodecParityTests` grew this machinery for `set_rule`, and it caught the
/// failure it was written for. But the failure is not about rules: **a write tool
/// whose arguments mirror a model has the same hole**, because the model is
/// `Codable` (the compiler grows its serialization for free) and the input schema
/// is hand-written (nothing grows it at all). Adding a field to `ClientCertificate`
/// or `ReverseProxyEndpoint` compiles everywhere, and the agent simply never gains
/// the ability to set it.
///
/// The render side learned this three times and now runs a 40-entry census
/// (`RenderParityTests`). The schema side had exactly one entry. This file is what
/// makes the second, third and seventh cheap enough to write.
///
/// ## What a census is, and is not
///
/// It is **one-directional and name-based**: every stored property of the model
/// must reach a schema property of the expected name, or be recorded as a
/// deliberate omission with a reason. A schema is free to advertise *more* than the
/// model holds — `replay_flow`'s `count`, `resume`'s `abort` — so extra properties
/// are never an error.
///
/// It is not a type check. A schema saying `"port": .string` where the model holds
/// an `Int` passes here and is caught by `MCPArgumentValidation` at the call
/// instead. The hole this closes is the silent one: a field that reaches the agent
/// under no name at all.
enum SchemaCensus {
    // MARK: - Model side

    /// Values whose internals are not model structure — recursing into `UUID`
    /// exposes its `uuid` byte tuple, into `Date` its `timeIntervalSince…`, and so on.
    private static func isLeaf(_ value: Any) -> Bool {
        value is String || value is Int || value is Bool || value is Double
            || value is UUID || value is Date || value is Data
    }

    /// Every stored property of a value and everything it holds, recursively.
    ///
    /// Reflection, deliberately, **not** the Codable encoding: a freshly-added
    /// `var probe: String?` is absent from the JSON whenever it is nil, so an
    /// encoding-based census silently blesses exactly the drift this exists to
    /// catch. `Mirror` reports the property either way.
    ///
    /// - Parameter opaqueFields: property names whose *contents* are not model
    ///   structure. The label itself is still recorded; only the recursion stops.
    ///   See `defaultOpaqueFields`.
    static func fieldNames(
        of value: Any,
        opaqueFields: Set<String> = defaultOpaqueFields
    ) -> Set<String> {
        if isLeaf(value) { return [] }
        var names: Set<String> = []
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .dictionary:
            return [] // free-form data: keys are values, not fields
        case .optional:
            // `nil` has no child, which is fine — the label was recorded by the
            // parent before it recursed here.
            if let wrapped = mirror.children.first?.value {
                names.formUnion(fieldNames(of: wrapped, opaqueFields: opaqueFields))
            }
        default:
            for child in mirror.children {
                guard let label = child.label, !label.isEmpty else {
                    // Collection element.
                    names.formUnion(fieldNames(of: child.value, opaqueFields: opaqueFields))
                    continue
                }
                names.insert(label)
                guard !opaqueFields.contains(label) else { continue }
                names.formUnion(fieldNames(of: child.value, opaqueFields: opaqueFields))
            }
        }
        return names
    }

    /// Fields whose insides are not model structure. Two kinds, and both were found
    /// by a census walking into them and demanding the schema advertise what it
    /// found:
    ///
    /// - **User data.** `query`, `headers`, `setHeaders` hold names the operator
    ///   chose. Recursing treats a header name as a field of the model.
    ///   `HeaderPair`'s own `name`/`value` therefore never reach a census either,
    ///   which is right: both the schema and the render represent headers as a
    ///   name→value object rather than as a list of pairs, so there is nothing to
    ///   compare.
    /// - **Derived caches.** `RuleMatch.preparedGlob` is a `Glob.Pattern` built from
    ///   `urlPattern` + `style`; its `segments` / `asciiLowercased` internals are an
    ///   implementation of matching, not something an agent could ever send. The
    ///   field name is still recorded, so the *cache itself* still has to be
    ///   accounted for as a deliberate omission — only its insides are off-limits.
    static let defaultOpaqueFields: Set<String> = [
        "query", "headers", "setHeaders", "preparedGlob",
    ]

    // MARK: - Schema side

    /// Property names anywhere in a tool's advertised input schema, recursively.
    ///
    /// The schemas nest (`match`, `actions`, `actions.mock_response`, …) and the
    /// model field list is flat, so both sides are flattened to be comparable. Only
    /// `properties` keys are collected, so schema keywords (`type`, `description`,
    /// `items`) can never masquerade as field names.
    static func schemaPropertyNames(ofTool name: String) throws -> Set<String> {
        let executor = MCPToolExecutor(engine: StubEngine(), appVersion: "9.9", protocolVersion: "x")
        let definition = try #require(
            executor.toolDefinitions.first { $0["name"] as? String == name },
            "no tool named \(name) is advertised"
        )
        let schema = try #require(definition["inputSchema"] as? [String: Any])
        return propertyNames(in: schema)
    }

    private static func propertyNames(in schema: [String: Any]) -> Set<String> {
        var names: Set<String> = []
        if let properties = schema["properties"] as? [String: Any] {
            for (name, nested) in properties {
                names.insert(name)
                if let nested = nested as? [String: Any] {
                    names.formUnion(propertyNames(in: nested))
                }
            }
        }
        if let items = schema["items"] as? [String: Any] {
            names.formUnion(propertyNames(in: items))
        }
        if let alternatives = schema["oneOf"] as? [Any] {
            for alternative in alternatives {
                guard let alternative = alternative as? [String: Any] else { continue }
                names.formUnion(propertyNames(in: alternative))
            }
        }
        return names
    }

    /// `deviceIP` → `device_ip`, `isRegex` → `is_regex`: lowercase runs of capitals
    /// as one word so an acronym doesn't become `device_i_p`.
    static func snakeCased(_ name: String) -> String {
        var out = ""
        var previousWasUpper = false
        for (offset, character) in name.enumerated() {
            if character.isUppercase {
                let nextIsLower = name.index(name.startIndex, offsetBy: offset + 1) < name.endIndex
                    && name[name.index(name.startIndex, offsetBy: offset + 1)].isLowercase
                if offset > 0, !previousWasUpper || nextIsLower { out.append("_") }
                out.append(Character(character.lowercased()))
                previousWasUpper = true
            } else {
                out.append(character)
                previousWasUpper = false
            }
        }
        return out
    }

    // MARK: - The comparison

    /// One tool's schema checked against one model.
    ///
    /// - Parameters:
    ///   - tool: the advertised tool name, e.g. `"set_client_certificate"`.
    ///   - modelFields: stored-property names, from `fieldNames(of:)`.
    ///   - aliases: model field → wire name, where mechanical snake_casing is wrong.
    ///   - omissions: model field → why the schema deliberately doesn't advertise it.
    static func check(
        tool: String,
        modelFields: Set<String>,
        aliases: [String: String] = [:],
        omissions: [String: String] = [:],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let advertised = try schemaPropertyNames(ofTool: tool)

        for field in modelFields.sorted() {
            let expected = aliases[field] ?? snakeCased(field)
            if advertised.contains(expected) { continue }
            if let reason = omissions[field] {
                #expect(
                    reason.count > 20,
                    "\(tool): the omission of `\(field)` needs a real reason, not \"\(reason)\"",
                    sourceLocation: sourceLocation
                )
                continue
            }
            Issue.record(
                """
                \(tool): model field `\(field)` has no input-schema property \
                (expected `\(expected)`). An agent cannot set what the schema never \
                mentions. Either advertise it, record an alias if it ships under \
                another name, or record it in `omissions` with the reason.
                """,
                sourceLocation: sourceLocation
            )
        }

        // A note that outlived the thing it explained is worse than no note: it
        // reads as a considered decision about a field that no longer exists. This
        // caught two dead entries in `set_rule`'s list the day it was written —
        // both describing Codable *coding keys*, which are not stored properties
        // and so were never anything a `Mirror` census could ask about.
        //
        // Deliberately not applied to `aliases`. An alias names a wire key, and a
        // model field can be one branch of a sum type (`MockBody.text` vs
        // `.bytes`) — mutually exclusive, so no single fixture exercises both, and
        // an alias for the branch this fixture didn't take is indistinguishable
        // from one for a field that is gone. An omission has no such excuse: it
        // names a stored property, which `Mirror` reports whether or not it holds
        // anything.
        let staleOmissions = Set(omissions.keys).subtracting(modelFields)
        #expect(
            staleOmissions.isEmpty,
            "\(tool): `omissions` explains \(staleOmissions.sorted()), which the model no longer has.",
            sourceLocation: sourceLocation
        )
    }
}
