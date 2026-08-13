import LoomSharedModels
import SwiftUI

/// Bottom pane of the main window. Layout referenced from Proxyman (not copied):
/// a left/right split — **Request** on the left, **Response** on the right — each
/// with its own tab strip. Fields are limited to what Loom actually captures.
///
/// The split is not quite symmetric, and the exception is deliberate: the left
/// pane's first tab is `FlowSummary`, which reports the whole exchange rather
/// than the request. A summary is a fact about the flow, and the alternatives are
/// worse — a third pane costs width two dozen rows do not justify, and splitting
/// it in two would put the status code, the timing and the connection on the
/// right while the URL and the method stay on the left, which is a summary of
/// nothing. See DESIGN.md § inspector-parity.
struct InspectorPanel: View {
    let flow: Flow
    let original: Flow?
    let onClose: () -> Void

    var body: some View {
        HSplitView {
            RequestPane(flow: flow, original: original)
                .frame(minWidth: 300)
            ResponsePane(flow: flow, onClose: onClose)
                .frame(minWidth: 300)
        }
    }
}
