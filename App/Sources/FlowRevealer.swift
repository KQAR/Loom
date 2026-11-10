import AppFeature
import ComposableArchitecture
import Foundation
import LoomSharedModels
import MCPServer

/// `reveal_flow`'s app half: open the main window and select the flow in it.
///
/// **Does not activate Loom.** The window is opened (or raised among Loom's own
/// windows) through the same channel a Dock click uses, but focus stays with whatever
/// the human is typing into — an agent pulling the foreground out from under them
/// mid-keystroke is the opposite of supervision. The tool tells the agent to say
/// "switch to Loom" instead.
@MainActor
enum FlowRevealer {
    static func reveal(_ id: Flow.ID, in store: StoreOf<AppFeature>) async -> FlowRevealOutcome {
        MainWindowRequests.shared.request()
        // The agent usually asks right after `wait_for_flow`, and the window learns of a
        // flow from the capture stream's next batch — so a just-captured flow can be a
        // beat ahead of its row. Wait briefly for it rather than call it missing.
        // ponytail: fixed 1 s poll; a stream-driven wait if this ever proves short.
        for _ in 0..<10 where store.capture.flows.value[id: id] == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let plan = store.capture.revealPlan(for: id) else {
            return FlowRevealOutcome(
                shown: false,
                reason: "The flow exists but isn't among the rows the window holds (it is older "
                    + "than the window's newest \(FlowLimits.windowRows)), so the human cannot "
                    + "select it there. Give them the flow id or its URL instead."
            )
        }
        store.send(.capture(.revealFlow(id)))
        return FlowRevealOutcome(shown: true, cleared: plan.map {
            switch $0 {
            case .sidebarSelection: .sidebarSelection
            case .findBar: .findBar
            case .quickFilters: .quickFilters
            }
        })
    }
}
