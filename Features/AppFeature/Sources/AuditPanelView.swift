import ComposableArchitecture
import LoomSharedModels
import SwiftUI

/// The main-window audit surface (sidebar → Audit). A read-only, chronological
/// timeline of every write action taken through Loom — the agent replays a
/// request, adds a rule, arms a breakpoint, changes the SSL scope — so the
/// supervising human can see what was done to real traffic (Loom's whole point
/// is that the MCP surface *can* write; this is where a human watches it). Reads
/// are never logged, so this only ever shows writes.
///
/// Ordered oldest→newest (newest at the bottom, like the flow list), tail-
/// following to the newest on entry. Each row is one scannable line (sequence
/// number + status + tool + time); clicking a row opens a detail **sheet** (like
/// the rule editor) with up/down controls to step through actions in place.
struct AuditPanelView: View {
    let store: StoreOf<AppFeature>
    /// The entry whose detail sheet is open, if any.
    @State private var sheetID: AuditEntry.ID?

    var body: some View {
        Group {
            if store.auditEntries.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        // A sheet, not a popover — a focused modal window like RuleEditorView.
        .sheet(isPresented: Binding(get: { sheetID != nil }, set: { if !$0 { sheetID = nil } })) {
            if let sheetID {
                AuditDetailSheet(entries: store.auditEntries, currentID: sheetID)
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(store.auditEntries.enumerated()), id: \.element.id) { idx, entry in
                    AuditRow(entry: entry, sequence: idx + 1) { sheetID = entry.id }
                        .id(entry.id)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset)
            // Tail-follow: land on the newest (bottom) on entry, and stay there as
            // new actions arrive.
            .onAppear { scrollToNewest(proxy) }
            .onChange(of: store.auditEntries.count) { scrollToNewest(proxy) }
        }
    }

    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        guard let last = store.auditEntries.last?.id else { return }
        proxy.scrollTo(last, anchor: .bottom)
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
    let sequence: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: LoomTheme.Space.sm) {
                Text("\(sequence)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 28, alignment: .trailing)
                Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(LoomTheme.Icon.card)
                    .foregroundStyle(entry.succeeded ? Color.green : Color.red)
                    .help(entry.succeeded ? "Succeeded" : "Failed")
                Text(entry.tool)
                    .font(.callout.weight(.medium).monospaced())
                if entry.source != .mcp {
                    CapsuleBadge(text: entry.source.rawValue.uppercased(), hPadding: 5, vPadding: 1)
                }
                Spacer(minLength: LoomTheme.Space.xs)
                Text(AuditFormat.time.string(from: entry.timestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, LoomTheme.Space.xxs)
    }
}

// MARK: - Detail sheet

/// Full detail for one audit entry, presented as a modal sheet (like the rule
/// editor). Up/down step through the timeline in place — the list is oldest→
/// newest, so ▲ = older, ▼ = newer.
private struct AuditDetailSheet: View {
    let entries: IdentifiedArrayOf<AuditEntry>
    @State var currentID: AuditEntry.ID
    @Environment(\.dismiss) private var dismiss

    private var index: Int? { entries.index(id: currentID) }
    private var entry: AuditEntry? { entries[id: currentID] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let entry {
                ScrollView {
                    VStack(alignment: .leading, spacing: LoomTheme.Space.md) {
                        if !entry.arguments.isEmpty, entry.arguments != "{}" {
                            block("Arguments", entry.arguments, tint: .primary)
                        }
                        if !entry.detail.isEmpty {
                            block(entry.succeeded ? "Result" : "Error", entry.detail,
                                  tint: entry.succeeded ? .primary : Color.red)
                        }
                    }
                    .padding(LoomTheme.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: 560, height: 460)
    }

    private var header: some View {
        HStack(spacing: LoomTheme.Space.sm) {
            if let entry {
                Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.title3)
                    .foregroundStyle(entry.succeeded ? Color.green : Color.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.tool).font(.headline.monospaced())
                    Text(AuditFormat.full.string(from: entry.timestamp))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let index {
                Text("\(index + 1) / \(entries.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { step(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .help("Older action")
                Button { step(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index >= entries.count - 1)
                    .help("Newer action")
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(LoomTheme.Space.md)
    }

    private func step(_ delta: Int) {
        guard let index else { return }
        let next = index + delta
        guard entries.indices.contains(next) else { return }
        currentID = entries[next].id
    }

    private func block(_ label: String, _ text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.xxs) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout.monospaced())
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private enum AuditFormat {
    static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    static let full: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium; return f
    }()
}
