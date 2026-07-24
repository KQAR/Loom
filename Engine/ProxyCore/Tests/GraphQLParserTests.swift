import Foundation
import Testing
import SharedModels

@Suite struct GraphQLParserTests {
    private func request(method: String = "POST", body: String?) -> CapturedRequest {
        CapturedRequest(method: method, url: "https://api.test/graphql", headers: [], body: body.map { Data($0.utf8) })
    }

    @Test func parsesQueryOperationNameAndVariables() {
        let op = GraphQLParser.parse(request(body: #"{"operationName":"GetHome","query":"query GetHome { home { id } }","variables":{"id":"5","x":1}}"#))
        #expect(op?.kind == .query)
        #expect(op?.operationName == "GetHome")
        #expect(op?.query == "query GetHome { home { id } }")
        #expect(op?.variablesJSON != nil)
        #expect(op?.variablesJSON?.contains("\"id\"") ?? false)
    }

    @Test(arguments: [
        (body: #"{"query":"mutation { like(id:1) }"}"#, kind: GraphQLOperation.Kind.mutation),
        (body: #"{"query":"{ me { name } }"}"#, kind: .query), // shorthand → query
    ])
    func infersKind(body: String, kind: GraphQLOperation.Kind) {
        #expect(GraphQLParser.parse(request(body: body))?.kind == kind)
    }

    @Test func emptyVariablesOmitted() {
        let op = GraphQLParser.parse(request(body: #"{"query":"{ a }","variables":{}}"#))
        #expect(op?.variablesJSON == nil)
    }

    @Test(arguments: [
        (method: "POST", body: Optional(#"{"user":"jane"}"#)), // not a GraphQL envelope
        (method: "GET", body: nil),                            // no body
        (method: "POST", body: Optional("not json")),
    ])
    func rejectsNonGraphQL(method: String, body: String?) {
        #expect(GraphQLParser.parse(request(method: method, body: body)) == nil)
    }
}
