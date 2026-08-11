import Testing
import Foundation
import LoomSharedModels
@testable import MCPServer

/// What `JSONSchema` has to keep true for the surface built on it: the JSON it
/// emits is the JSON an agent used to get, and the one distinction that decides
/// whether argument validation runs at all — declared-but-empty versus free-form —
/// survives every node type.
@Suite struct MCPSchemaTests {
    // MARK: The emission rules

    @Test func aNoArgumentTool_advertisesAnEmptyPropertyMap() {
        // Not an absent `properties`: that is what a free-form map looks like, and
        // it would switch unknown-argument rejection off for the tool.
        let json = JSONSchema.object().json
        #expect(json["type"] as? String == "object")
        let properties = json["properties"] as? [String: Any]
        #expect(properties?.isEmpty == true)
        #expect(json["required"] == nil)
    }

    @Test func aFreeformObject_advertisesNoProperties() {
        let json = JSONSchema.freeformObject("Header name/value pairs.").json
        #expect(json["type"] as? String == "object")
        #expect(json["properties"] == nil)
        #expect(json["description"] as? String == "Header name/value pairs.")
    }

    @Test func absentFieldsEmitNoKeys() {
        // An absent description must not become an empty string, and an absent enum
        // must not become an empty array: either would read to the agent as a
        // constraint that was never written.
        let json = JSONSchema.string().json
        #expect(json.keys.sorted() == ["type"])
    }

    @Test func anEmptyRequired_emitsNoKey() {
        // JSON Schema treats `"required": []` and an absent `required` identically;
        // `set_rule` is the tool that has neither, being an upsert.
        #expect(JSONSchema.object(["a": .string()]).json["required"] == nil)
    }

    @Test func oneOf_carriesNoTypeOfItsOwn() {
        let json = JSONSchema.oneOf([.integer(), .string()], description: "A number or a class.").json
        #expect(json["type"] == nil)
        #expect((json["oneOf"] as? [[String: Any]])?.count == 2)
        #expect(json["description"] as? String == "A number or a class.")
    }

    @Test func anArray_carriesItsElementSchema() {
        let json = JSONSchema.array(of: .string(), "Header names to remove.").json
        #expect(json["type"] as? String == "array")
        #expect((json["items"] as? [String: Any])?["type"] as? String == "string")
    }

    @Test func nestingSurvivesSerialization() throws {
        // The whole point of the type is that the nested case still produces plain
        // JSON — a node three deep has to come out as a dictionary, not as a value
        // `JSONSerialization` refuses.
        let schema = JSONSchema.object([
            "actions": .object([
                "substitutions": .array(of: .object(["field": .string(allowed: ["url"])], required: ["field"])),
            ]),
        ])
        let data = try JSONSerialization.data(withJSONObject: schema.json, options: [.sortedKeys])
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let actions = try #require((decoded["properties"] as? [String: Any])?["actions"] as? [String: Any])
        let substitutions = try #require((actions["properties"] as? [String: Any])?["substitutions"] as? [String: Any])
        let element = try #require(substitutions["items"] as? [String: Any])
        let field = try #require((element["properties"] as? [String: Any])?["field"] as? [String: Any])
        #expect(field["enum"] as? [String] == ["url"])
        #expect(element["required"] as? [String] == ["field"])
    }

    @Test func adding_keepsTheSharedHalfAndTheToolsOwn() {
        let schema = JSONSchema.object(["host": .string()]).adding(["limit": .integer()])
        #expect(schema.properties?.keys.sorted() == ["host", "limit"])
    }

    // MARK: The registry-wide invariant

    @Test func everyToolAdvertisesADeclaredObject() {
        // A tool whose top-level schema were free-form (`properties` absent) would
        // accept **any** argument name silently — `MCPArgumentValidation` returns
        // early on exactly that node. The dictionary version could reach that state
        // by omitting one key; here it is one call away too, so it is pinned.
        for tool in MCPToolExecutor.tools {
            #expect(tool.inputSchema.kind == .object, "\(tool.name) must take an object")
            #expect(
                tool.inputSchema.properties != nil,
                "\(tool.name) advertises a free-form top level, so unknown arguments would pass"
            )
        }
    }

    @Test func everyRequiredKeyIsDeclared() {
        // Also asserted at construction, which only fires in a debug build of the
        // app; this covers a release one, and names the tool.
        for tool in MCPToolExecutor.tools {
            for key in tool.inputSchema.required {
                #expect(
                    tool.inputSchema.properties?[key] != nil,
                    "\(tool.name) requires \"\(key)\" without declaring it"
                )
            }
        }
    }
}
