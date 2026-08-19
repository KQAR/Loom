import Foundation
import Testing
@testable import AppFeature

/// In-pane find for Body. Distinct from the window's "Find in Requests",
/// which filters the table — these pin the matching itself: case folding,
/// and that a JSON container is expanded rather than counted when only a
/// child matches.
@Suite struct InspectorFindTests {
    @Test func rangesAreCaseInsensitiveAndInOrder() {
        let text = "Foo bar FOO"
        let ranges = InspectorFindMatch.ranges(of: "foo", in: text)
        #expect(ranges.count == 2)
        #expect(String(text[ranges[0]]) == "Foo")
        #expect(String(text[ranges[1]]) == "FOO")
    }

    @Test func emptyNeedleIsNoRanges() {
        #expect(InspectorFindMatch.ranges(of: "  ", in: "abc").isEmpty)
        #expect(InspectorFindMatch.ranges(of: "x", in: "").isEmpty)
    }

    @Test func jsonCountsTheMatchingLineNotItsAncestors() throws {
        let json = try #require(JSONValue.parse(Data(#"{"user":{"id":1,"name":"Ada"}}"#.utf8)))
        #expect(InspectorFindMatch.jsonMatchCount(json, needle: "ada") == 1)
        #expect(InspectorFindMatch.jsonMatchCount(json, needle: "id") == 1)
        #expect(InspectorFindMatch.jsonMatchCount(json, needle: "nope") == 0)
    }

    @Test func jsonExpandsAncestorsOfAMatch() throws {
        let json = try #require(JSONValue.parse(Data(#"{"user":{"id":1,"name":"Ada"}}"#.utf8)))
        let expand = InspectorFindMatch.jsonExpansionPaths(json, needle: "ada")
        // Root and `user` must be in the open-set so the matching `name` line
        // can be revealed. The view ORs this with already-expanded nodes.
        #expect(expand.contains([]))
        #expect(expand.contains([0]))
        #expect(InspectorFindMatch.jsonExpansionPaths(json, needle: "nope").isEmpty)
    }

    @Test func jsonPathsAreDocumentOrder() throws {
        let json = try #require(JSONValue.parse(Data(#"{"a":"x","b":{"c":"x"}}"#.utf8)))
        let index = InspectorFindMatch.jsonIndex(json, needle: "x")
        #expect(index.paths == [[0], [1, 0]])
        #expect(index.path(at: 0) == [0])
        #expect(index.path(at: 1) == [1, 0])
    }

    @Test func pairFieldsMatchNameOrValue() {
        #expect(InspectorFindMatch.fieldsMatch(["Content-Type", "application/json"], needle: "json"))
        #expect(InspectorFindMatch.fieldsMatch(["Content-Type", "application/json"], needle: "content"))
        #expect(!InspectorFindMatch.fieldsMatch(["Content-Type", "application/json"], needle: "cookie"))
        #expect(!InspectorFindMatch.fieldsMatch(["Accept", "text/html"], needle: "  "))
    }

    @Test func cookieFieldsIncludeAttributes() {
        #expect(InspectorFindMatch.fieldsMatch(["sid", "abc", "HttpOnly"], needle: "httponly"))
        #expect(!InspectorFindMatch.fieldsMatch(["sid", "abc", ""], needle: "httponly"))
    }

    @Test func steppingWraps() {
        var find = InspectorFind()
        find.step(by: 1, matchCount: 3)
        #expect(find.currentIndex == 1)
        find.step(by: -1, matchCount: 3)
        #expect(find.currentIndex == 0)
        find.step(by: -1, matchCount: 3)
        #expect(find.currentIndex == 2)
    }
}
