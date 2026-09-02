import ComposableArchitecture
import LoomSharedModels
import SwiftUI

/// The address popover: what port the proxy listens on, and the only place it can be
/// changed.
///
/// It hangs off the toolbar's `ip:port` chip because that is the thing it edits —
/// the address a client is pointed at is read there, so it is where someone goes when
/// 9090 is taken by something else on the machine (the measured case is a dev server
/// that will not move).
///
/// Three things it states rather than leaves to be discovered:
///
/// - **the SOCKS listener rides one port above**, so choosing 9090 spends 9091 too;
/// - **applying rebinds**, which drops whatever is connected — a proxy cannot move
///   its listener without closing it;
/// - **the system proxy follows** when Loom holds it, because that setting stores a
///   port and would otherwise point at a listener that has moved.
struct ProxyPortCard: View {
    @Bindable var store: StoreOf<AppFeature>
    /// Called when a rebind lands, so the popover closes itself. A card that stays
    /// open on success leaves the operator to dismiss a form whose work is done, and
    /// the thing it was editing is already visible behind it.
    var onApplied: () -> Void = {}

    @State private var text = ""
    @FocusState private var focused: Bool
    /// Whether *this* card started the rebind in flight. Without it the card would
    /// dismiss on a rebind someone else caused (an agent's write, a LAN toggle).
    @State private var applying = false

    private var parsed: Int? { Int(text.trimmingCharacters(in: .whitespaces)) }

    /// Live refusal for what is typed — the reducer validates again, since it is the
    /// side that decides what reaches the engine.
    private var refusal: String? {
        guard let parsed else {
            return text.isEmpty ? nil : "Ports are numbers."
        }
        return ListenPortRules.refusal(
            for: parsed,
            reserved: [ListenPortRules.mcpControlPort: "Loom's MCP control port"],
            inUseByLoom: Set(store.status.reverseProxies.compactMap(\.boundPort))
        )
    }

    private var canApply: Bool {
        guard let parsed, refusal == nil else { return false }
        return parsed != store.status.port || !store.status.isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
            header
            Divider()
            field
            footnotes
            if let message = refusal ?? store.portError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(LoomTheme.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button { apply() } label: {
                    HStack(spacing: LoomTheme.Space.xs) {
                        if store.portRebinding {
                            // The listener is down for the length of this: the button
                            // says so rather than looking like a click that missed.
                            ProgressView().controlSize(.small)
                        }
                        Text(store.portRebinding ? "Applying…" : "Apply")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply || store.portRebinding)
            }
        }
        .padding(LoomTheme.Space.md)
        .frame(width: 320)
        .onAppear {
            text = String(store.configuredPort)
            focused = true
        }
        .onChange(of: store.portRebinding) { wasRebinding, isRebinding in
            // Finished. `portError` is the verdict — a failed rebind keeps the card
            // open, because the message is the only thing that says what to try next.
            guard applying, wasRebinding, !isRebinding else { return }
            applying = false
            if store.portError == nil { onApplied() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: LoomTheme.Space.xs) {
            Text("Proxy Address").font(.headline)
            Spacer(minLength: LoomTheme.Space.sm)
            if store.portRebinding {
                ProgressView().controlSize(.small)
            }
            Button {
                MainView.copy("\(store.displayHost):\(store.status.port)")
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy the proxy address")
        }
    }

    private var field: some View {
        HStack(spacing: LoomTheme.Space.xs) {
            Text(verbatim: "\(store.displayHost):")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            TextField("Port", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .frame(width: 90)
                .focused($focused)
                .onSubmit { if canApply { apply() } }
        }
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.xxs) {
            if let parsed, refusal == nil {
                Text("SOCKS listens on \(parsed + 1).")
            }
            Text("Applying rebinds the listeners — anything connected is dropped.")
            if store.setup.isSystemProxy {
                Text("The system proxy will be pointed at the new port.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func apply() {
        guard let parsed else { return }
        applying = true
        store.send(.portSubmitted(parsed))
    }
}
