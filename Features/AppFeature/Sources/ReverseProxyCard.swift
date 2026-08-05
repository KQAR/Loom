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
/// The endpoints are read from `status.reverseProxies` (the one mirror, refreshed by
/// `engineStatusRefreshed`) rather than being copied into a second list here — two
/// mirrors of the same ports is how the header and this card would come to disagree.
struct ReverseProxyCard: View {
    @Bindable var store: StoreOf<AppFeature>

    /// Form state, held in the view because it is transient and dies with the form.
    @State private var upstream = ""
    @State private var port = ""
    @State private var label = ""
    @State private var keepHostHeader = false
    @State private var adding = false
    @State private var pendingDeletion: ReverseProxyStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
            if store.status.reverseProxies.isEmpty {
                Text("No endpoints. Add one for a client that ignores proxy settings — Node's fetch/undici does — then point that client's target at the local port instead of the real origin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Not-listening first, for the same reason the header orders them that
                // way: a port that didn't bind reads to its client as Loom being down.
                ForEach(ordered) { status in
                    row(status)
                }
            }

            if adding {
                form
            } else {
                HStack(spacing: LoomTheme.Space.sm) {
                    Button {
                        adding = true
                    } label: {
                        Label("Add…", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.reverseProxyBusy)

                    if store.reverseProxyBusy {
                        ProgressView().controlSize(.small)
                    }
                }
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
        .confirmationDialog(
            "Remove this reverse proxy?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { status in
            Button("Remove", role: .destructive) {
                store.send(.deleteReverseProxyTapped(id: status.endpoint.id))
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { status in
            // Confirmed because the damage is outside Loom: whatever config still names
            // this port (a dev server, a container env) starts getting connection
            // refused, and Loom can't put that back.
            Text("Port \(String(status.boundPort ?? status.endpoint.requestedPort)) stops listening. Anything still pointed at it — a dev server's proxy target, an env var — gets connection refused until you change it back to \(status.endpoint.upstream).")
        }
    }

    /// Not-listening endpoints first, then oldest-first — the same order as the
    /// console header's caption lines, so the two read as one list.
    private var ordered: [ReverseProxyStatus] {
        store.status.reverseProxies.sorted { lhs, rhs in
            lhs.isListening == rhs.isListening
                ? lhs.endpoint.createdAt < rhs.endpoint.createdAt
                : !lhs.isListening
        }
    }

    // MARK: Rows

    private func row(_ status: ReverseProxyStatus) -> some View {
        HStack(alignment: .top, spacing: LoomTheme.Space.sm) {
            Image(systemName: status.isListening ? "arrow.left.arrow.right" : "exclamationmark.triangle.fill")
                .font(LoomTheme.Icon.badge)
                .foregroundStyle(status.isListening ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                // The local URL is what goes into a config file, so it's the primary
                // line and it's selectable — retyping a port by eye is how the wrong
                // one ends up in the config.
                Text(status.localURL ?? "port \(String(status.endpoint.requestedPort)) — not listening")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(caption(for: status))
                    .font(.caption2)
                    .foregroundStyle(status.isListening ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: LoomTheme.Space.xs)
            Button {
                pendingDeletion = status
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

    /// One line that answers "where does this go, and is it working". A bind failure
    /// is stated in full: it is the case this list exists for, and its client
    /// experiences it as connection refused rather than as an error from Loom.
    private func caption(for status: ReverseProxyStatus) -> String {
        if let error = status.error { return "Not listening — \(error)" }
        var parts = ["→ \(status.endpoint.upstream)"]
        if let label = status.endpoint.label, !label.isEmpty { parts.append(label) }
        if status.endpoint.keepHostHeader { parts.append("keeps Host header") }
        return parts.joined(separator: " · ")
    }

    // MARK: Add form

    private var form: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.xs) {
            TextField("Upstream, e.g. https://api.example.com", text: $upstream)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            TextField("Local port (blank = pick one for me)", text: $port)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            TextField("Label (optional)", text: $label)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            // Off by default, and the label says which way round it matters: a real
            // server usually vhost-routes on Host, so sending it 127.0.0.1 returns a
            // 404 that reads as Loom having broken the request.
            Toggle("Keep the client's Host header", isOn: $keepHostHeader)
                .controlSize(.small)
                .font(.caption)

            HStack(spacing: LoomTheme.Space.sm) {
                Button("Add") {
                    store.send(.addReverseProxyTapped(
                        upstream: upstream.trimmingCharacters(in: .whitespaces),
                        // Blank means "any free port" (the engine's 0), not 0 typed by
                        // hand; a non-numeric entry is refused by `canAdd` first.
                        port: Int(port.trimmingCharacters(in: .whitespaces)) ?? 0,
                        label: trimmedLabel,
                        keepHostHeader: keepHostHeader
                    ))
                    reset()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canAdd || store.reverseProxyBusy)

                Button("Cancel") { reset() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var trimmedLabel: String? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The upstream is validated properly by the engine (scheme, host, no query) and
    /// its message is what the human reads. This only screens what the form itself can
    /// know: something was typed, and a typed port is a port.
    private var canAdd: Bool {
        guard !upstream.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let typedPort = port.trimmingCharacters(in: .whitespaces)
        guard !typedPort.isEmpty else { return true }
        guard let value = Int(typedPort) else { return false }
        return (1...65535).contains(value)
    }

    private func reset() {
        adding = false
        upstream = ""
        port = ""
        label = ""
        keepHostHeader = false
    }
}
