import SwiftUI

/// Capture-wide connection totals shown when the Connections filter is active.
///
/// These are engine aggregates over retained history, not a scan of the visible
/// table. The "capture totals" label prevents a composed host/device filter from
/// making the global numbers look like the filtered result.
struct ConnectionSummaryBar: View {
    let connections: Int
    let failed: Int
    let relayed: Int
    let coversHistory: Bool

    var body: some View {
        HStack(spacing: LoomTheme.Space.xs) {
            Image(systemName: "link")
                .font(.caption)
            Text("Capture totals")
            Text("\(connections) connections")
                .monospacedDigit()
            Text("·")
                .foregroundStyle(.tertiary)
            Text("\(failed) failed")
                .monospacedDigit()
            Text("·")
                .foregroundStyle(.tertiary)
            Text("\(relayed) relayed")
                .monospacedDigit()
            if !coversHistory {
                Text("· counting history…")
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, LoomTheme.Space.sm)
        .padding(.vertical, LoomTheme.Space.xxs)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}
