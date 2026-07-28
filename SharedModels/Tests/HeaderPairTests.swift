import Foundation
import Testing
import LoomSharedModels

/// Header names are case-insensitive and the list is ordered and may repeat a
/// name, so "remove this header" is one definition worth having in one place —
/// rule rewrites, breakpoint edits and replay all mean the same thing by it.
@Suite struct HeaderPairTests {
    private let headers = [
        HeaderPair(name: "X-Trace", value: "1"),
        HeaderPair(name: "Accept", value: "*/*"),
        HeaderPair(name: "x-trace", value: "2"),
    ]

    @Test func removeAllNamed_dropsEveryCaseVariant() {
        var headers = headers
        headers.removeAll(named: "X-TRACE")
        #expect(headers == [HeaderPair(name: "Accept", value: "*/*")], "both repeats, either casing")
    }

    @Test func removeAllNamed_missingNameLeavesTheListAlone() {
        var headers = headers
        headers.removeAll(named: "Authorization")
        #expect(headers.count == 3)
    }

    @Test func removeAllNamedAnyOf_dropsEachListedName() {
        var headers = headers
        headers.removeAll(namedAnyOf: ["accept", "X-Trace"])
        #expect(headers.isEmpty)
    }

    @Test func removeAllNamedAnyOf_emptyListIsANoOp() {
        var headers = headers
        headers.removeAll(namedAnyOf: [])
        #expect(headers == self.headers)
    }

    /// Order of what survives is preserved — a proxy that reorders headers is
    /// reporting something the wire never carried.
    @Test func removalPreservesOrderOfSurvivors() {
        var headers = [
            HeaderPair(name: "A", value: "1"),
            HeaderPair(name: "B", value: "2"),
            HeaderPair(name: "C", value: "3"),
            HeaderPair(name: "b", value: "4"),
            HeaderPair(name: "D", value: "5"),
        ]
        headers.removeAll(namedAnyOf: ["B"])
        #expect(headers.map(\.name) == ["A", "C", "D"])
    }
}
