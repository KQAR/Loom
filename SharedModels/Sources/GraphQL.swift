import Foundation

/// A parsed GraphQL operation extracted from a request body. GraphQL rides over
/// HTTP as a POST whose JSON body carries `query` (+ optional `operationName`,
/// `variables`), so a debugger can show the operation instead of an opaque blob.
public struct GraphQLOperation: Equatable, Sendable {
    /// query / mutation / subscription, inferred from the query text.
    public enum Kind: String, Sendable {
        case query, mutation, subscription, unknown
    }

    public var kind: Kind
    public var operationName: String?
    public var query: String
    /// Pretty-printed variables JSON, if any were sent.
    public var variablesJSON: String?

    public init(kind: Kind, operationName: String?, query: String, variablesJSON: String?) {
        self.kind = kind
        self.operationName = operationName
        self.query = query
        self.variablesJSON = variablesJSON
    }

    /// A short label like `query GetHome` / `mutation` for lists and tabs.
    public var label: String {
        if let operationName, !operationName.isEmpty { return "\(kind.rawValue) \(operationName)" }
        return kind.rawValue
    }
}

public enum GraphQLParser {
    /// Parse a GraphQL operation from a request, or nil when it isn't GraphQL.
    /// Recognizes a POST whose JSON body has a `query` string (the de-facto
    /// transport used by Apollo, Relay, urql, etc.).
    public static func parse(_ request: CapturedRequest) -> GraphQLOperation? {
        guard request.method.uppercased() == "POST", let body = request.body, !body.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        guard let query = object["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        var variablesJSON: String?
        if let variables = object["variables"] as? [String: Any], !variables.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: variables, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            variablesJSON = String(decoding: data, as: UTF8.self)
        }

        return GraphQLOperation(
            kind: inferKind(query),
            operationName: object["operationName"] as? String,
            query: query,
            variablesJSON: variablesJSON
        )
    }

    private static func inferKind(_ query: String) -> GraphQLOperation.Kind {
        // The first significant keyword sets the operation type; a bare `{ ... }`
        // is a shorthand query.
        let trimmed = query.drop { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }
        if trimmed.hasPrefix("mutation") { return .mutation }
        if trimmed.hasPrefix("subscription") { return .subscription }
        if trimmed.hasPrefix("query") || trimmed.hasPrefix("{") { return .query }
        return .unknown
    }
}
