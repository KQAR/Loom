import LoomSharedModels
import SwiftUI

/// Bottom pane of the main window. Layout referenced from Proxyman (not copied):
/// a **header** carrying the selected request's URL (and the close control), then
/// a left/right split — **Request** on the left, **Response** on the right — each
/// with its own tab strip. Fields are limited to what Loom actually captures.
///
/// The URL lives on the header, not inside the Request pane, because it is a
/// fact about the whole exchange and the close control has to sit on the same
/// line: a request-only bar left the Response pane without an address, and hid
/// ✕ in that pane's tab strip. See DESIGN.md `{components.inspector-panel}`.
///
/// The split is not quite symmetric, and the exception is deliberate: the left
/// pane's first tab is `FlowSummary`, which reports the whole exchange rather
/// than the request. A summary is a fact about the flow, and the alternatives are
/// worse — a third pane costs width two dozen rows do not justify, and splitting
/// it in two would put the status code, the timing and the connection on the
/// right while the method stays on the left, which is a summary of nothing. See
/// DESIGN.md § inspector-parity.
struct InspectorPanel: View {
    let flow: Flow
    let original: Flow?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                RequestPane(flow: flow, original: original)
                    .frame(minWidth: 300)
                ResponsePane(flow: flow)
                    .frame(minWidth: 300)
            }
        }
        .onAppear { WireTextSystemMenu.install() }
    }

    /// The selected request's URL, spanning both panes, with ✕ trailing.
    ///
    /// Copy is the URL's right-click menu, not a button, so `{md}` is only
    /// keeping the string off ✕. Deselecting is how the inspector hides (the
    /// table then fills the pane).
    private var header: some View {
        HStack(spacing: LoomTheme.Space.md) {
            CopyableURLBar(url: flow.request.url)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Close detail")
            .help("Close detail")
        }
        .padding(.horizontal, LoomTheme.Space.md)
        .padding(.vertical, LoomTheme.Space.xs)
    }
}
