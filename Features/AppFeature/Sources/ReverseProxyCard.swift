import ComposableArchitecture
import LoomSharedModels
import SwiftUI

/// The reverse-proxy endpoint list plus the form that creates one: a local port that
/// stands in for one upstream origin.
///
/// Lives in the status-bar console because per DESIGN v3 the console *is* the
/// configuration surface. Deliberately **not** a sidebar panel like Rules /
/// Breakpoints / Audit: those exist for activity that needs supervising while it
/// happens, whereas an endpoint is created once, written into a dev server's config,
/// and then left alone (it outlives relaunches for exactly that reason).
///
/// Why the human gets a form at all, when `create_reverse_proxy` already exists over
/// MCP: an endpoint is a *listening port on this machine*, and pointing a dev server
/// at it is a step only the human can take — they own the config file. Leaving
/// creation agent-only meant the one thing that makes this feature usable was
/// unreachable without an agent in the loop.
///
/// This is the **sole** place endpoints are reported to the human, agent-created ones
/// included; the caption lines that used to list them under the console header's
/// address were removed with this card's arrival. Endpoints are the one listener list
/// whose other writer is an agent, so two renderings meant two things to keep in step —
/// and the header was the rendering with no room for the URL to copy, the upstream, or
/// a Remove button.
///
/// The endpoints are read from `status.reverseProxies` (the one mirror, refreshed by
/// `engineStatusRefreshed`) rather than being copied into a second list here.
struct ReverseProxyCard: View {
    @Bindable var store: StoreOf<AppFeature>

    /// Form state, held in the view because it is transient and dies with the form. The
    /// validation rules live in `ReverseProxyDraft`, not here, so they can be tested.
    @State private var draft = ReverseProxyDraft()
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
            if store.status.reverseProxies.isEmpty {
                Text("No endpoints. Add one for a client that ignores proxy settings — Node's fetch/undici does — then point that client's target at the local port instead of the real origin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let listed = ReverseProxyList.rows(for: store.status.reverseProxies)
                ForEach(listed.rows) { status in
                    row(status)
                }
                if listed.hidden > 0 {
                    // Never silently truncated — the count says what is missing, and
                    // where to see the rest.
                    Text("+\(listed.hidden) more — ask your agent for list_reverse_proxies")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if adding {
                form
            } else {
                // Bottom-right: the list is what this card is for, so the one thing that
                // adds to it sits after it, at the trailing edge, out of the reading path
                // rather than above the first row.
                HStack(spacing: LoomTheme.Space.sm) {
                    if store.reverseProxyBusy {
                        ProgressView().controlSize(.small)
                    }
                    Spacer(minLength: LoomTheme.Space.xs)
                    Button {
                        adding = true
                    } label: {
                        Label("Add…", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.reverseProxyBusy)
                }
                .frame(maxWidth: .infinity)
            }

            if let message = store.reverseProxyMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(LoomTheme.Space.sm)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: LoomTheme.Radius.sm))
    }

    // MARK: Rows

    /// One endpoint. The trash button removes it **immediately** — no confirmation, and
    /// no reveal gesture in front of it.
    ///
    /// Undoing a mistake here is retyping the same two fields in the form directly below,
    /// and the endpoint's own row says what they were. That is cheap enough that a guard
    /// costs more than the mistake: a dialog is impossible in this popover anyway (see
    /// `RevealToDelete`), and the reveal it was replaced with was still two taps for a
    /// recreatable thing. `ClientCertificatesCard` keeps the reveal, because a removed
    /// identity needs the original `.p12` back.
    private func row(_ status: ReverseProxyStatus) -> some View {
        HStack(alignment: .top, spacing: LoomTheme.Space.sm) {
            VStack(alignment: .leading, spacing: 1) {
                // The local URL is what goes into a config file, so it's the primary
                // line and it's selectable — retyping a port by eye is how the wrong
                // one ends up in the config.
                Text(ReverseProxyList.target(for: status))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ReverseProxyList.caption(for: status))
                    .font(.caption2)
                    .foregroundStyle(status.isListening ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: LoomTheme.Space.xs)
            Button {
                store.send(.deleteReverseProxyTapped(id: status.endpoint.id))
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .disabled(store.reverseProxyBusy)
            .accessibilityLabel("Remove the reverse proxy for \(status.endpoint.upstream)")
            .help("Stop listening on this port and forget the endpoint")
        }
    }

    // MARK: Add form

    /// Port and upstream share one line, joined by an arrow, because that is what the
    /// endpoint *is*: this local port forwards to that origin. Two stacked fields made
    /// the reader assemble the relationship themselves.
    ///
    /// There is no Label field. A label only disambiguates two endpoints pointing at the
    /// same host, which is rare enough not to earn a third input on a 300pt panel — and
    /// an agent can still set one over MCP, so the list still renders it.
    private var form: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.xs) {
            HStack(spacing: LoomTheme.Space.xs) {
                TextField("port", text: $draft.port)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 64)
                    .monospaced()
                Image(systemName: "arrow.right")
                    .font(LoomTheme.Icon.badge)
                    .foregroundStyle(.secondary)
                TextField("https://api.example.com", text: $draft.upstream)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }

            // Live, and only about what has actually been typed: a blank port is a
            // legitimate "pick one for me", so an empty field says nothing.
            if let problem = draft.portProblem ?? draft.upstreamProblem {
                Text(problem)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if draft.port.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Leave the port blank and Loom picks a free one.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Off by default, and the label says which way round it matters: a real
            // server usually vhost-routes on Host, so sending it 127.0.0.1 returns a
            // 404 that reads as Loom having broken the request.
            Toggle("Keep the client's Host header", isOn: $draft.keepHostHeader)
                .controlSize(.small)
                .font(.caption)

            HStack(spacing: LoomTheme.Space.sm) {
                Spacer(minLength: LoomTheme.Space.xs)
                Button("Cancel") { reset() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Add") {
                    store.send(.addReverseProxyTapped(
                        upstream: draft.submittedUpstream,
                        port: draft.submittedPort,
                        // Human-created endpoints carry no label — the field is gone; an
                        // agent's can, and the list renders it either way.
                        label: nil,
                        keepHostHeader: draft.keepHostHeader
                    ))
                    reset()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!draft.canSubmit || store.reverseProxyBusy)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func reset() {
        adding = false
        draft = ReverseProxyDraft()
    }
}
