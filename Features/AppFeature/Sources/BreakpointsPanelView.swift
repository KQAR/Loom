import ComposableArchitecture
import LoomSharedModels
import SwiftUI

/// The main-window breakpoint surface (sidebar → Breakpoints). Two sections, in
/// the order that matters to a supervisor:
///
/// 1. **Held** — exchanges parked right now. Each one is a live client connection
///    waiting on a decision, so this is the section that must never be invisible:
///    it leads, it's coloured, and every row carries both decisions (let it
///    through / abort it) inline. No confirmation on either: the exchange is
///    already stalled, and a dialog between the human and the release is the
///    opposite of what this surface is for.
/// 2. **Armed** — the breakpoints an agent set. Read-only apart from disarm;
///    authoring stays with the agent (`set_breakpoint` over MCP).
///
/// Editing a held request before releasing it is deliberately *not* here — see
/// `BreakpointsFeature`.
struct BreakpointsPanelView: View {
    let store: StoreOf<BreakpointsFeature>

    var body: some View {
        VStack(spacing: 0) {
            header
            if let message = store.message {
                HStack(spacing: LoomTheme.Space.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(LoomTheme.Palette.error)
                .padding(.horizontal, LoomTheme.Space.md)
                .padding(.vertical, LoomTheme.Space.xs)
            }
            Divider()
            if store.pending.isEmpty, store.armed.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .onAppear { store.send(.refresh) }
    }

    private var header: some View {
        HStack(spacing: LoomTheme.Space.sm) {
            Text(summaryText)
                .font(.callout)
                .foregroundStyle(store.pending.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(LoomTheme.Palette.warning))
            Spacer()
            if !store.pending.isEmpty {
                Button {
                    for held in store.pending { store.send(.resumeTapped(held.id)) }
                } label: {
                    Label("Resume All", systemImage: "play")
                }
                .controlSize(.small)
                .help("Let every held exchange continue, unmodified")
            }
        }
        .padding(.horizontal, LoomTheme.Space.md)
        .padding(.vertical, LoomTheme.Space.sm)
    }

    private var summaryText: String {
        let held = store.pending.count
        let armed = store.armed.count
        if held == 0 {
            return armed == 0 ? "No breakpoints" : "\(armed) armed · nothing held"
        }
        return "\(held) held · \(armed) armed"
    }

    private var list: some View {
        List {
            if !store.pending.isEmpty {
                Section("Held") {
                    ForEach(store.pending) { held in
                        HeldRow(
                            held: held,
                            onResume: { store.send(.resumeTapped(held.id)) },
                            onAbort: { store.send(.abortTapped(held.id)) }
                        )
                        .listRowSeparator(.hidden)
                    }
                }
            }
            if !store.armed.isEmpty {
                Section("Armed") {
                    // One pass over the held exchanges, not one filter per armed
                    // row (that was O(held × armed) per render).
                    let heldCounts = Dictionary(grouping: store.pending, by: \.breakpointID).mapValues(\.count)
                    ForEach(store.armed) { breakpoint in
                        ArmedRow(
                            breakpoint: breakpoint,
                            heldCount: heldCounts[breakpoint.id] ?? 0,
                            onDisarm: { store.send(.disarmTapped(breakpoint.id)) }
                        )
                        .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No breakpoints", systemImage: "pause.circle")
        } description: {
            Text("Ask your agent to call `set_breakpoint`. Traffic it holds appears here — with the connection still open — until it's released or aborted.")
        }
    }
}

// MARK: - Held row

/// One parked exchange. Reads like a flow row (method · host · path) plus the two
/// things only a hold has: which phase it's stopped in, and since when.
private struct HeldRow: View {
    let held: PendingBreakpoint
    let onResume: () -> Void
    let onAbort: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: LoomTheme.Space.sm) {
            Image(systemName: "pause.circle.fill")
                .font(LoomTheme.Icon.card)
                .foregroundStyle(LoomTheme.Palette.warning)
                .help("Held — the client is still waiting")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: LoomTheme.Space.xs) {
                    Text(held.method).font(.callout.weight(.medium).monospaced())
                    CapsuleBadge(text: phaseText, hPadding: 5, vPadding: 1)
                    if let code = held.statusCode {
                        Text("\(code)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(held.url)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(BreakpointFormat.time.string(from: held.heldAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Held since \(BreakpointFormat.full.string(from: held.heldAt))")

            Button(action: onResume) {
                Label("Resume", systemImage: "play.fill")
            }
            .controlSize(.small)
            .help("Let it continue unmodified")

            Button(role: .destructive, action: onAbort) {
                Label("Abort", systemImage: "xmark")
            }
            .controlSize(.small)
            .help("Kill the exchange — the client gets a 502")
        }
        .padding(.vertical, 2)
    }

    private var phaseText: String {
        held.phase == .request ? "REQUEST" : "RESPONSE"
    }
}

// MARK: - Armed row

private struct ArmedRow: View {
    let breakpoint: Breakpoint
    /// How many exchanges this breakpoint is holding right now.
    let heldCount: Int
    let onDisarm: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: LoomTheme.Space.sm) {
            Image(systemName: "pause.circle")
                .font(LoomTheme.Icon.card)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: LoomTheme.Space.xs) {
                    Text(patternText)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ForEach(phaseBadges, id: \.self) { badge in
                        CapsuleBadge(text: badge, hPadding: 5, vPadding: 1)
                    }
                    if heldCount > 0 {
                        Text("holding \(heldCount)")
                            .font(.caption)
                            .foregroundStyle(LoomTheme.Palette.warning)
                    }
                }
                if let comment = breakpoint.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .destructive, action: onDisarm) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel("Disarm this breakpoint")
            // The engine keeps already-held exchanges parked after a disarm, so say so.
            .help(heldCount > 0
                ? "Disarm — exchanges it already holds still need a decision"
                : "Disarm this breakpoint")
        }
        .padding(.vertical, 2)
    }

    /// Same shape as the rules panel's pattern line — a breakpoint reuses `RuleMatch`.
    private var patternText: String {
        var parts: [String] = []
        if !breakpoint.match.methods.isEmpty {
            parts.append(breakpoint.match.methods.joined(separator: "/").uppercased())
        }
        parts.append(breakpoint.match.isRegex ? "/\(breakpoint.match.urlPattern)/" : breakpoint.match.urlPattern)
        return parts.joined(separator: " ")
    }

    private var phaseBadges: [String] {
        var badges: [String] = []
        if breakpoint.onRequest { badges.append("REQ") }
        if breakpoint.onResponse { badges.append("RES") }
        return badges
    }
}

private enum BreakpointFormat {
    static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    static let full: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium; return f
    }()
}
