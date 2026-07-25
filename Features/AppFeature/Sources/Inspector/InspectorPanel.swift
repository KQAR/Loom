import LoomSharedModels
import SwiftUI

/// Bottom pane of the main window. Layout referenced from Proxyman (not copied):
/// a left/right split — **Request** on the left, **Response** on the right — each
/// with its own tab strip. Fields are limited to what Loom actually captures.
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
