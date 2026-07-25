import LoomSharedModels
import SwiftUI

struct SummaryTable: View {
    let flow: Flow
    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
            row("Status", statusText)
            row("Method", flow.request.method)
            if let code = flow.statusCode { row("Code", "\(code)") }
            if let host = flow.host { row("Host", host) }
            if let ms = flow.durationMS { row("Duration", "\(ms) ms") }
            // The split that tells you *where* a slow call is slow: waiting on the
            // server vs transferring the body.
            if let ttfb = flow.ttfbMS {
                row("TTFB", "\(ttfb) ms" + (flow.receiveMS.map { " · \($0) ms transfer" } ?? ""))
            }
            row("Started", flow.startedAt.formatted(date: .abbreviated, time: .standard))
            if flow.replayedFrom != nil { row("Origin", "Replayed") }
            if let importedFrom = flow.importedFrom { row("Origin", "Imported from \(importedFrom)") }
            if let applied = flow.appliedRules, !applied.isEmpty {
                row("Rules", applied.map(\.name).joined(separator: ", "), color: .accentColor)
            }
            if let error = flow.error { row("Error", error, color: .red) }
        }
        .font(.callout)
    }

    private var statusText: String {
        if flow.error != nil { return "Failed" }
        return flow.response != nil ? "Completed" : "In progress"
    }

    private func row(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack(alignment: .top, spacing: LoomTheme.Space.md) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .foregroundStyle(color)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
