import LoomSharedModels
import SwiftUI

/// One rule in the Rules panel. Click the name (or the pencil) to edit.
struct RulesPanelRow: View {
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

            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: LoomTheme.Space.xs) {
                        Text(rule.name)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(dimmed ? .secondary : .primary)
                        ForEach(actionBadges, id: \.self) { badge in
                            CapsuleBadge(text: badge, hPadding: 5, vPadding: 1)
                        }
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

    private var dimmed: Bool {
        !rule.isEnabled || !engineEnabled || !groupEnabled || rule.match.isExpired
    }

    private var patternText: String { RuleSummary.patternText(for: rule) }
    private var actionBadges: [String] { RuleSummary.actionBadges(for: rule) }
    private var scopeBadges: [RuleSummary.ScopeBadge] { RuleSummary.scopeBadges(for: rule) }
}
