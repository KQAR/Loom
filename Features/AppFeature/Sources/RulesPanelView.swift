import ComposableArchitecture
import SharedModels
import SwiftUI

/// The main-window rules surface (sidebar → Rules). The agent authors rules over
/// MCP; here the human supervises them: master switch, per-group and per-rule
/// enable/disable, delete. Grouping is display + batch-toggle only — evaluation
/// order stays the flat list order.
struct RulesPanelView: View {
    @Bindable var store: StoreOf<AppFeature>
    /// Collapsed groups, keyed by `groupKey` (nil group has its own sentinel).
    @State private var collapsed: Set<String> = []

    /// Groups in order of first appearance (mirrors evaluation order); ungrouped
    /// rules form their own bucket keyed `nil`.
    private var groups: [(key: String?, rules: [TrafficRule])] {
        var order: [String?] = []
        var buckets: [String?: [TrafficRule]] = [:]
        for rule in store.rulesState.rules {
            if buckets[rule.group] == nil { order.append(rule.group) }
            buckets[rule.group, default: []].append(rule)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let message = store.rulesMessage {
                HStack(spacing: LoomTheme.Space.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, LoomTheme.Space.md)
                .padding(.vertical, LoomTheme.Space.xs)
            }
            Divider()
            if store.rulesState.rules.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                rulesList
            }
        }
        .onAppear { store.send(.refreshRules) }
    }

    // The master switch lives on the toolbar's wand icon; this bar is just the
    // rule count and the New Rule action.
    private var header: some View {
        HStack(spacing: LoomTheme.Space.sm) {
            Text(summaryText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                store.send(.newRuleTapped)
            } label: {
                Label("New Rule", systemImage: "plus")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, LoomTheme.Space.md)
        .padding(.vertical, LoomTheme.Space.sm)
    }

    private var summaryText: String {
        let total = store.rulesState.rules.count
        guard total > 0 else { return "No rules" }
        let active = store.enabledRules.count
        guard store.rulesEnabled else { return "\(total) rules · engine off" }
        return "\(active) of \(total) active"
    }

    private var rulesList: some View {
        List {
            ForEach(groups, id: \.key) { group in
                groupHeader(group.key, rules: group.rules)
                if !collapsed.contains(Self.groupKey(group.key)) {
                    ForEach(group.rules) { rule in
                        RuleRow(
                            rule: rule,
                            engineEnabled: store.rulesEnabled,
                            onToggle: { store.send(.ruleToggled(rule.id)) },
                            onEdit: { store.send(.editRuleTapped(rule.id)) },
                            onDelete: { store.send(.ruleDeleted(rule.id)) }
                        )
                        .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    /// Stable key for the collapsed set (Optional in a Set is awkward; sentinel for nil).
    private static func groupKey(_ group: String?) -> String { group ?? "\u{0}__ungrouped__" }

    /// Collapsible group header. The leading checkmark toggles the whole group on/off
    /// (aligned with the per-rule checkboxes below); the label toggles collapse.
    private func groupHeader(_ group: String?, rules: [TrafficRule]) -> some View {
        let allOn = rules.allSatisfy(\.isEnabled)
        let isCollapsed = collapsed.contains(Self.groupKey(group))
        return HStack(spacing: LoomTheme.Space.sm) {
            // Batch enable/disable — checkmark at the left start, not a switch.
            Toggle(isOn: Binding(
                get: { allOn },
                set: { store.send(.ruleGroupToggled(group: group, enabled: $0)) }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .help(group == nil ? "Enable/disable all ungrouped rules" : "Enable/disable the whole group")

            Button {
                if isCollapsed { collapsed.remove(Self.groupKey(group)) }
                else { collapsed.insert(Self.groupKey(group)) }
            } label: {
                HStack(spacing: LoomTheme.Space.xs) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: group == nil ? "tray" : "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(group ?? "Ungrouped")
                        .font(.callout.weight(.semibold))
                    Text("\(rules.count)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No rules yet", systemImage: "wand.and.stars")
        } description: {
            Text("Ask your agent to call `create_rule`, or right-click a captured request → Add Rule.")
        }
    }
}

// MARK: - Row

private struct RuleRow: View {
    let rule: TrafficRule
    let engineEnabled: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: LoomTheme.Space.sm) {
            Toggle(isOn: Binding(get: { rule.isEnabled }, set: { _ in onToggle() })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .help(rule.isEnabled ? "Disable this rule" : "Enable this rule")

            // The info block is a button: click (or double-click the row) to edit.
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: LoomTheme.Space.xs) {
                        Text(rule.name)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(dimmed ? .secondary : .primary)
                        ForEach(actionBadges, id: \.self) { badge in
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(patternText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let comment = rule.comment, !comment.isEmpty {
                        Text(comment)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit this rule")

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Edit this rule")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Delete this rule")
        }
        .padding(.vertical, 2)
        .opacity(engineEnabled ? 1 : 0.55)
    }

    private var dimmed: Bool { !rule.isEnabled || !engineEnabled }

    private var patternText: String {
        var parts: [String] = []
        if !rule.match.methods.isEmpty {
            parts.append(rule.match.methods.joined(separator: "/").uppercased())
        }
        parts.append(rule.match.isRegex ? "/\(rule.match.urlPattern)/" : rule.match.urlPattern)
        return parts.joined(separator: " ")
    }

    private var actionBadges: [String] {
        let a = rule.actions
        var badges: [String] = []
        if a.block { badges.append("BLOCK") }
        if a.mockResponse != nil { badges.append("MOCK") }
        if a.mapRemote != nil { badges.append("MAP REMOTE") }
        if a.mapLocal != nil { badges.append("MAP LOCAL") }
        if a.rewriteRequest?.isEmpty == false { badges.append("REQ") }
        if a.rewriteResponse?.isEmpty == false { badges.append("RES") }
        if let ms = a.delayMilliseconds { badges.append("DELAY \(ms)ms") }
        return badges
    }
}
