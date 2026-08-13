import Foundation
import LoomSharedModels
import Testing
@testable import AppFeature

/// What a *set* of sidebar categories means.
///
/// The sidebar went from one selected category to many, and a set of filters only
/// answers a question once two things are pinned down: which combinations are
/// legal (`normalizeSelection`) and how the legal ones compose
/// (`FlowCategory.Dimension` — OR within, AND across). Both are easy to get
/// subtly wrong in a way that shows as "the list is missing rows" rather than as
/// a crash.
@Suite struct SidebarSelectionTests {
    private let phone = SourceDevice(ip: "192.168.1.9", kind: .lan, platform: "Android", client: nil)
    private let mac = SourceDevice(ip: "127.0.0.1", kind: .local)

    private func flow(
        host: String = "a.test", status: Int = 200, app: String? = nil, device: SourceDevice? = nil
    ) -> Flow {
        Flow(
            request: CapturedRequest(method: "GET", url: "https://\(host)/v1", headers: []),
            startedAt: Date(timeIntervalSince1970: 0),
            outcome: .completed(
                CapturedResponse(statusCode: status, headers: []), at: Date(timeIntervalSince1970: 1)
            ),
            sourceApp: app.map { SourceApp(name: $0, bundleID: $0, pid: 1) },
            sourceDevice: device
        )
    }

    private func state(_ flows: [Flow], _ selection: Set<FlowCategory>) -> CaptureFeature.State {
        var state = CaptureFeature.State(flows: flows)
        state.selection = selection
        return state
    }

    // MARK: - Normalization

    @Test func anEmptySelectionIsEverything() {
        // Clicking the sidebar's background deselects; an empty set would mean
        // "show nothing", which no click intends.
        #expect(FlowCategory.normalizeSelection([], previous: [.host("a.test")]) == [.all])
    }

    @Test func aPanelIsExclusiveInBothDirections() {
        // Adding a panel to a set of filters drops the filters…
        #expect(
            FlowCategory.normalizeSelection(
                [.host("a.test"), .rules], previous: [.host("a.test")]
            ) == [.rules]
        )
        // …and adding a filter while a panel is up drops the panel, which is the
        // half that would otherwise leave the table hidden behind a panel the human
        // thought they had just left.
        #expect(
            FlowCategory.normalizeSelection(
                [.rules, .host("a.test")], previous: [.rules]
            ) == [.host("a.test")]
        )
    }

    @Test func allIsExclusiveTheSameWay() {
        #expect(
            FlowCategory.normalizeSelection([.all, .host("a.test")], previous: [.all]) == [.host("a.test")]
        )
        #expect(
            FlowCategory.normalizeSelection([.host("a.test"), .all], previous: [.host("a.test")]) == [.all]
        )
    }

    @Test func filtersCompose() {
        let selection = FlowCategory.normalizeSelection(
            [.host("a.test"), .host("b.test"), .device("192.168.1.9")], previous: [.host("a.test")]
        )
        #expect(selection.count == 3)
    }

    // MARK: - What a set selects

    @Test func twoHostsMeanEitherHost() {
        let flows = [flow(host: "a.test"), flow(host: "b.test"), flow(host: "c.test")]
        let state = state(flows, [.host("a.test"), .host("b.test")])
        #expect(Set(state.displayFlows.compactMap(\.host)) == ["a.test", "b.test"])
    }

    @Test func aHostAndADeviceMeanBoth() {
        // Across dimensions is AND — "this host, from the phone" is the whole point
        // of being able to pick two.
        let wanted = flow(host: "a.test", device: phone)
        let flows = [
            wanted,
            flow(host: "a.test", device: mac),
            flow(host: "b.test", device: phone),
        ]
        let state = state(flows, [.host("a.test"), .device("192.168.1.9")])
        #expect(state.displayFlows.map(\.id) == [wanted.id])
    }

    @Test func aDeviceAndOneOfItsAppsMeanTheDevice() {
        // Devices and apps are one dimension, so this is a union and the device —
        // the superset the human also clicked — wins. AND-ing them would answer
        // with the app alone, which is the smaller of the two things picked.
        let flows = [
            flow(host: "a.test", app: "com.one", device: phone),
            flow(host: "b.test", app: "com.two", device: phone),
            flow(host: "c.test", device: mac),
        ]
        let state = state(flows, [.device("192.168.1.9"), .app(device: "192.168.1.9", key: "com.one")])
        #expect(state.displayFlows.count == 2, "both of the phone's flows, not just com.one's")
    }

    @Test func theSameAppOnTwoDevicesIsTwoDifferentSelections() {
        let onPhone = flow(host: "a.test", app: "com.shared", device: phone)
        let onMac = flow(host: "a.test", app: "com.shared", device: mac)
        let state = state([onPhone, onMac], [.app(device: "192.168.1.9", key: "com.shared")])
        #expect(state.displayFlows.map(\.id) == [onPhone.id],
                "an app row belongs to the device it is drawn under")
    }

    @Test func errorsNarrowWhateverElseIsPicked() {
        let broken = flow(host: "a.test", status: 500)
        let flows = [broken, flow(host: "a.test"), flow(host: "b.test", status: 500)]
        let state = state(flows, [.errors, .host("a.test")])
        #expect(state.displayFlows.map(\.id) == [broken.id])
    }

    @Test func aPanelSelectionEmptiesTheTable() {
        let state = state([flow()], [.rules])
        #expect(state.displayFlows.isEmpty)
        #expect(state.panelCategory == .rules)
    }

    // MARK: - The projection stays in step

    @Test func theIncrementalFoldAgreesWithARebuildUnderAMultiSelection() {
        // `recordFlows` folds a batch into the cached projection instead of
        // rebuilding it; with a multi-selection that fold is running the new
        // dimension logic per row, and it must land on the same list.
        var state = state(
            [flow(host: "a.test"), flow(host: "b.test")],
            [.host("a.test"), .host("b.test")]
        )
        state.recordFlows([flow(host: "a.test"), flow(host: "c.test"), flow(host: "b.test")])

        var rebuilt = state
        rebuilt.refreshVisibleFlows()
        #expect(state.displayFlows.map(\.id) == rebuilt.displayFlows.map(\.id))
        #expect(state.displayFlows.count == 4, "c.test is in neither selected host")
    }
}
