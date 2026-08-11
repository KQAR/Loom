import ComposableArchitecture
import LoomSharedModels
import SwiftUI

/// The main-window rules surface (sidebar → Rules). The agent authors rules over
/// MCP; here the human supervises them: master switch, per-group and per-rule
/// enable/disable, delete. A group has a switch of its own (`RulesState.disabledGroups`)
/// that composes with each rule's — switching a scenario off never overwrites which
/// rules the human had turned off inside it. Evaluation order stays the flat list order.
struct RulesPanelView: View {
    @Bindable var store: StoreOf<RulesFeature>
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
                .foregroundStyle(LoomTheme.Palette.error)
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
            // Glyph-only, like the console cards' `plus` (DESIGN.md § Components):
            // the panel's whole content is the rule list, so the one button on its
            // header can't be adding anything else, and the word was spending width
            // on a fact the position already gives. Tooltip and accessibility label
            // still say it.
            GlyphButton(systemImage: "plus", help: "New rule", size: GlyphButton.compact) {
                store.send(.newRuleTapped)
            }
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
                            groupEnabled: store.rulesState.isGroupEnabled(group.key),
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
        // The group's own switch, not "are all its rules on" — those are different
        // facts now, and reading the second would show a group with one
        // individually-disabled rule as switched off.
        let groupOn = store.rulesState.isGroupEnabled(group)
        let isCollapsed = collapsed.contains(Self.groupKey(group))
        return HStack(spacing: LoomTheme.Space.sm) {
            // Switches the whole group; each rule keeps its own flag.
            Toggle(isOn: Binding(
                get: { groupOn },
                set: { store.send(.ruleGroupToggled(group: group, enabled: $0)) }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .tint(LoomTheme.Palette.accent)
            .help(group == nil
                ? "Switch the ungrouped rules on or off (each rule keeps its own switch)"
                : "Switch the whole group on or off (each rule keeps its own switch)")

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
            Text("Ask your agent to call `set_rule`, or right-click a captured request → Add Rule.")
        }
    }
}

// MARK: - Row

private struct RuleRow: View {
    let rule: TrafficRule
    let engineEnabled: Bool
    /// Its group's switch. A rule can be enabled and still inert because the group
    /// it belongs to is off — the row has to show that, or the checkbox lies.
    let groupEnabled: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: LoomTheme.Space.sm) {
            Toggle(isOn: Binding(get: { rule.isEnabled }, set: { _ in onToggle() })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .tint(LoomTheme.Palette.accent)
            .help(rule.isEnabled ? "Disable this rule" : "Enable this rule")

            // The info block is a button: click (or double-click the row) to edit.
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: LoomTheme.Space.xs) {
                        Text(rule.name)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(dimmed ? .secondary : .primary)
                        ForEach(actionBadges, id: \.self) { badge in
                            CapsuleBadge(text: badge, hPadding: 5, vPadding: 1)
                        }
                        // Tinted apart from the action badges: these say who the
                        // rule is limited to, not what it does.
                        ForEach(scopeBadges) { badge in
                            CapsuleBadge(text: badge.text, tint: LoomTheme.Palette.accent, hPadding: 5, vPadding: 1)
                                .help(badge.detail)
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
            .accessibilityLabel("Edit this rule")
            .help("Edit this rule")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel("Delete this rule")
            .help("Delete this rule")
        }
        .padding(.vertical, 2)
        .opacity(engineEnabled && groupEnabled ? 1 : 0.55)
    }

    private var dimmed: Bool { !rule.isEnabled || !engineEnabled || !groupEnabled }

    private var patternText: String { RuleSummary.patternText(for: rule) }
    private var actionBadges: [String] { RuleSummary.actionBadges(for: rule) }
    private var scopeBadges: [RuleSummary.ScopeBadge] { RuleSummary.scopeBadges(for: rule) }
}
