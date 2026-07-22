import XCTest
import SharedModels

final class GraphQLParserTests: XCTestCase {
    private func request(method: String = "POST", body: String?) -> CapturedRequest {
        CapturedRequest(method: method, url: "https://api.test/graphql", headers: [], body: body.map { Data($0.utf8) })
    }

    func test_parsesQueryOperationNameAndVariables() {
        let op = GraphQLParser.parse(request(body: #"{"operationName":"GetHome","query":"query GetHome { home { id } }","variables":{"id":"5","x":1}}"#))
        XCTAssertEqual(op?.kind, .query)
        XCTAssertEqual(op?.operationName, "GetHome")
        XCTAssertEqual(op?.query, "query GetHome { home { id } }")
        XCTAssertNotNil(op?.variablesJSON)
        XCTAssertTrue(op?.variablesJSON?.contains("\"id\"") ?? false)
    }

    func test_infersMutationAndShorthand() {
        XCTAssertEqual(GraphQLParser.parse(request(body: #"{"query":"mutation { like(id:1) }"}"#))?.kind, .mutation)
        XCTAssertEqual(GraphQLParser.parse(request(body: #"{"query":"{ me { name } }"}"#))?.kind, .query)
    }

    func test_emptyVariablesOmitted() {
        let op = GraphQLParser.parse(request(body: #"{"query":"{ a }","variables":{}}"#))
        XCTAssertNil(op?.variablesJSON)
    }

    func test_rejectsNonGraphQL() {
        XCTAssertNil(GraphQLParser.parse(request(body: #"{"user":"jane"}"#)))
        XCTAssertNil(GraphQLParser.parse(request(method: "GET", body: nil)))
        XCTAssertNil(GraphQLParser.parse(request(body: "not json")))
    }
}
