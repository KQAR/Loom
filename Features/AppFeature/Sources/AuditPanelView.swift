import ComposableArchitecture
import LoomSharedModels
import SwiftUI

/// The main-window audit surface (sidebar → Audit). A read-only, newest-first
/// timeline of every write action taken through Loom — the agent replays a
/// request, adds a rule, arms a breakpoint, changes the SSL scope — so the
/// supervising human can see what was done to real traffic (Loom's whole point
/// is that the MCP surface *can* write; this is where a human watches it). Reads
/// are never logged, so this only ever shows writes.
struct AuditPanelView: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.auditEntries.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.auditEntries) { entry in
                    AuditRow(entry: entry)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.inset)
            }
        }
    }

    private var header: some View {
        HStack(spacing: LoomTheme.Space.sm) {
            Text(summaryText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, LoomTheme.Space.md)
        .padding(.vertical, LoomTheme.Space.sm)
    }

    private var summaryText: String {
        let total = store.auditEntries.count
        guard total > 0 else { return "No write actions" }
        let failures = store.auditEntries.filter { !$0.succeeded }.count
        guard failures > 0 else { return "\(total) write actions" }
        return "\(total) write actions · \(failures) failed"
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No write actions yet", systemImage: "checklist")
        } description: {
            Text("Replays, rule changes, breakpoints and SSL-scope changes made through Loom appear here — so you can see what your agent did to real traffic.")
        }
    }
}

// MARK: - Row

private struct AuditRow: View {
    let entry: AuditEntry

    /// Time-of-day only; the full timestamp rides in the tooltip. One shared
    /// formatter (allocating one per row is wasteful in a long list).
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: LoomTheme.Space.sm) {
            Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(LoomTheme.Icon.card)
                .foregroundStyle(entry.succeeded ? Color.green : Color.red)
                .help(entry.succeeded ? "Succeeded" : "Failed")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: LoomTheme.Space.xs) {
                    Text(entry.tool)
                        .font(.callout.weight(.medium).monospaced())
                    // Only tag a non-agent source, so the common (agent) case stays
                    // uncluttered — a bare row is an MCP/agent write.
                    if entry.source != .mcp {
                        CapsuleBadge(text: entry.source.rawValue.uppercased(), hPadding: 5, vPadding: 1)
                    }
                    Spacer(minLength: LoomTheme.Space.xs)
                    Text(Self.time.string(from: entry.timestamp))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(Self.full.string(from: entry.timestamp))
                }
                if !entry.arguments.isEmpty, entry.arguments != "{}" {
                    Text(entry.arguments)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.caption2)
                        .foregroundStyle(entry.succeeded ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.red))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, LoomTheme.Space.xxs)
    }
}
