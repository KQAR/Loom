import ComposableArchitecture
import SharedModels
import XCTest

@testable import AppFeature

/// `TestStore` coverage for the parent `AppFeature` after the `RulesFeature`
/// split: boot idempotency, flow capture/replay/clear, and the cross-feature
/// seams (Add-Rule-from-flow → present editor, replay failure → rules message).
/// The rule CRUD itself is tested in `RulesFeatureTests`.
@MainActor
final class AppFeatureReducerTests: XCTestCase {
    private struct StubError: LocalizedError {
        var errorDescription: String? { "replay failed" }
    }

    // MARK: Boot idempotency

    func test_task_isNoOpOnceBooted() async {
        var initial = AppFeature.State()
        initial.didBoot = true // already booted; re-render must not restart the proxy
        let store = TestStore(initialState: initial) { AppFeature() }
        // No dependencies are overridden: if `.task` re-ran its effect it would
        // touch `proxyClient.start` (unimplemented) and fail the test.
        await store.send(.task)
    }

    // MARK: Add-Rule-from-flow seam (parent owns the flow store, child owns the editor)

    func test_addRuleFromFlow_stampsRuleAndPresentsEditor() async {
        let flow = Fixtures.flow()
        var initial = AppFeature.State()
        initial.flows = [flow]
        // Mock-from-flow now hydrates the full flow (bodies) via the client, since
        // the list holds metadata only.
        let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
            $0.proxyClient.flow = { _ in flow }
        }
        store.exhaustivity = .off // the stamped rule carries a fresh UUID/date

        await store.send(.addRuleFromFlow(flow.id, .mockResponse))
        await store.receive(\.rules.presentEditor)
        XCTAssertTrue(store.state.rules.editor?.isNew ?? false)
        guard case .mock = store.state.rules.editor?.rule.actions.route else {
            return XCTFail("expected a mock rule stamped from the flow")
        }
    }

    func test_addRuleFromFlow_unknownID_isNoOp() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() } withDependencies: {
            $0.proxyClient.flow = { _ in nil } // hydrate finds nothing → no editor
        }
        await store.send(.addRuleFromFlow(UUID(), .blockURL)) // no flow → nothing happens
    }

    // MARK: Replay failure routes into the shared rules message

    func test_replayTapped_failure_surfacesInRulesMessage() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.replay = { _, _ in throw StubError() }
        }
        await store.send(.replayTapped(UUID()))
        await store.receive(\.rules.ruleWriteFailed) {
            $0.rules.rulesMessage = "Replay failed: replay failed"
        }
    }

    // MARK: Replay success

    func test_replayFinished_insertsAndSelects() async {
        let original = UUID()
        let replayed = Fixtures.flow(id: UUID(), replayedFrom: original)
        let originalFlow = Fixtures.flow(id: original)
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() } withDependencies: {
            $0.proxyClient.flow = { id in id == original ? originalFlow : nil }
        }
        await store.send(.replayFinished(replayed)) {
            $0.flows[id: replayed.id] = replayed.strippingBodies() // list is body-free
            $0.selectedFlowID = replayed.id // jump to the replayed result
            $0.selectedFlowDetail = replayed // result still carries bodies
            $0.status.capturedCount = 1
        }
        // Effect fetches the replay's original for the inspector diff.
        await store.receive(\.selectedDetailLoaded) {
            $0.selectedOriginalDetail = originalFlow
        }
    }

    func test_replayFinished_nil_isNoOp() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        await store.send(.replayFinished(nil))
    }

    // MARK: Capture stream + clear

    func test_flowReceived_appendsAndCounts() async {
        let flow = Fixtures.flow()
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        await store.send(.flowReceived(flow)) {
            $0.flows[id: flow.id] = flow.strippingBodies() // list stores metadata only
            $0.status.capturedCount = 1
        }
    }

    func test_clearTapped_emptiesStore() async {
        let flow = Fixtures.flow()
        var initial = AppFeature.State()
        initial.flows = [flow]
        initial.selectedFlowID = flow.id
        initial.status.capturedCount = 1
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.clearFlows = { }
        }
        await store.send(.clearTapped) {
            $0.flows = []
            $0.selectedFlowID = nil
            $0.status.capturedCount = 0
        }
    }

    func test_toggleRecording_flips() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.setRecording = { _ in }
        }
        await store.send(.toggleRecordingTapped) {
            $0.isRecording = false // starts true
        }
    }
}
