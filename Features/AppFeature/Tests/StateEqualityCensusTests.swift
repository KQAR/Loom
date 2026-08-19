import Foundation
import Testing
@testable import AppFeature

/// `CaptureFeature.State.==` is written by hand, so it can go stale.
///
/// It is hand-written because `flows` and `visibleFlows` are `Versioned`, which is
/// deliberately not `Equatable` — that is what stops TCA's observation and SwiftUI's
/// AttributeGraph from diffing 20 000 `Flow`s on the main thread to learn something
/// the assignment already told them. The synthesized `==` went with it, and a
/// forgotten field in the replacement is worse than the cost it saves: a `TestStore`
/// assertion that passes while the two states differ.
///
/// So this counts. Add a stored property and this fails, which is the reminder to
/// add it to `==` as well.
@Suite struct StateEqualityCensusTests {
    /// Every stored property `CaptureFeature.State.==` compares, by name.
    private let compared: Set<String> = [
        "flows",
        "droppedFlowCount",
        "selection",
        "selectedFlowID",
        "search",
        "aggregates",
        "aggregatesCoverHistory",
        "hostByRow",
        "pinnedHosts",
        "pinnedApps",
        "deviceAliases",
        "visibleFlows",
        "visiblePositions",
        "selectionByDimension",
        "sidebarHosts",
        "sidebarDevices",
        "selectedFlowDetail",
        "selectedOriginalDetail",
    ]

    @Test func stateEqualityComparesEveryStoredProperty() {
        // The `@ObservableState` macro backs each *observed* stored property with
        // `_name` and adds its own `_$observationRegistrar`, which is not state. An
        // `@ObservationStateIgnored` property keeps its own name, so the underscore is
        // stripped only when it is there.
        let stored = Set(
            Mirror(reflecting: CaptureFeature.State()).children
                .compactMap(\.label)
                .filter { !$0.hasPrefix("_$") }
                .map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }
        )
        #expect(
            stored == compared,
            """
            CaptureFeature.State's stored properties and the ones `==` compares have \
            drifted. Missing from `==`: \(stored.subtracting(compared).sorted()). \
            Listed but gone: \(compared.subtracting(stored).sorted()).
            """
        )
    }

    /// The point of the hand-written `==`: it still means equal *contents*, so two
    /// states that reached the same window by different routes compare equal. A
    /// version stamp — the other way to make the comparison cheap — fails this,
    /// because the two routes assign a different number of times.
    @Test func twoRoutesToTheSameWindowAreEqual() {
        let flows = (0 ..< 5).map { i in
            Fixtures.flow(url: "https://a.test/\(i)")
        }
        var oneAtATime = CaptureFeature.State()
        for flow in flows { oneAtATime.recordFlow(flow) }
        let batched = CaptureFeature.State(flows: flows)
        #expect(oneAtATime == batched)
    }

    @Test func aDifferentWindowIsNotEqual() {
        let a = CaptureFeature.State(flows: [Fixtures.flow(url: "https://a.test/1")])
        let b = CaptureFeature.State(flows: [Fixtures.flow(url: "https://b.test/1")])
        #expect(a != b)
    }
}
