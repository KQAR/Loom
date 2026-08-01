import LoomSharedModels
import SwiftUI

/// The human half of the capture → modify → replay → **diff** loop.
///
/// It renders `FlowComparison` — the same value the `diff_flows` MCP tool
/// renders as JSON. Before, this view computed its own diff, and a weaker one:
/// request headers only, no response headers, and a body reported as the single
/// word "changed". The human supervising an agent was reading a different answer
/// than the agent had. Presentation is this file's job; what counts as a
/// difference is `FlowComparison`'s.
struct DiffView: View {
    let original: Flow?
    let replayed: Flow

    /// Computed once per flow pair, off the main actor, not per render: the LCS
    /// line diff (up to its 400-line cap) plus body decoding used to re-run on
    /// every inspector re-render — ~10×/s under live traffic with the Diff tab
    /// open, for a value that only changes when the pair does.
    @State private var comparison: FlowComparison?

    /// What the diff depends on: the pair's identity plus each side's body sizes
    /// and completion — hydration attaches bodies and completion fills the
    /// response, both under unchanged flow ids.
    private struct Key: Hashable {
        let base: UUID, compared: UUID
        let baseBytes: Int?, comparedBytes: Int?
        let baseDone: Date?, comparedDone: Date?
    }

    private var key: Key? {
        original.map {
            Key(
                base: $0.id, compared: replayed.id,
                baseBytes: ($0.request.body?.count ?? 0) + ($0.response?.body?.count ?? 0),
                comparedBytes: (replayed.request.body?.count ?? 0) + (replayed.response?.body?.count ?? 0),
                baseDone: $0.completedAt, comparedDone: replayed.completedAt
            )
        }
    }

    var body: some View {
        if let original {
            Group {
                if let comparison {
                    if comparison.isIdentical {
                        Text("Identical — same request, same response.")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
                            section("Request", rows: requestRows(comparison.request))
                            section("Response", rows: responseRows(comparison.response))
                            if let error = comparison.error {
                                section("Error", rows: [.change(label: "error", change: error.strings)])
                            }
                        }
                    }
                }
            }
            .task(id: key) {
                let base = original
                let compared = replayed
                let result = await Task.detached { FlowComparison.compare(base: base, compared: compared) }.value
                guard !Task.isCancelled else { return }
                comparison = result
            }
        }
    }

    // MARK: - Rows

    /// One line of the diff. Modelled rather than pre-formatted so added/removed
    /// body lines can carry their own styling.
    private enum Row: Identifiable {
        case change(label: String, change: (base: String?, compared: String?))
        case note(String)
        case bodyLine(added: Bool, text: String)

        var id: String {
            switch self {
            case let .change(label, change): return "c\(label)\(change.base ?? "")\(change.compared ?? "")"
            case let .note(text): return "n\(text)"
            case let .bodyLine(added, text): return "b\(added)\(text)"
            }
        }
    }

    private func requestRows(_ request: FlowComparison.MessageComparison) -> [Row] {
        var rows: [Row] = []
        if let method = request.method { rows.append(.change(label: "method", change: method.strings)) }
        if let url = request.url { rows.append(.change(label: "url", change: url.strings)) }
        rows.append(contentsOf: headerRows(request.headers))
        rows.append(contentsOf: bodyRows(request.body))
        return rows
    }

    private func responseRows(_ response: FlowComparison.ResponseComparison) -> [Row] {
        if let presence = response.presence {
            return [.note((presence.compared ?? false)
                ? "the replay answered; the original never did"
                : "the original answered; the replay never did")]
        }
        var rows: [Row] = []
        if let status = response.status { rows.append(.change(label: "status", change: status.strings)) }
        if let version = response.httpVersion { rows.append(.change(label: "httpVersion", change: version.strings)) }
        rows.append(contentsOf: headerRows(response.headers))
        rows.append(contentsOf: bodyRows(response.body))
        return rows
    }

    private func headerRows(_ headers: [FlowComparison.HeaderChange]) -> [Row] {
        headers.map { header in
            .change(
                label: "header \(header.name)",
                change: (header.base?.joined(separator: ", "), header.compared?.joined(separator: ", "))
            )
        }
    }

    private func bodyRows(_ body: FlowComparison.BodyComparison?) -> [Row] {
        guard let body else { return [] }
        let sizes = "body: \(body.baseBytes) → \(body.comparedBytes) bytes"
        switch body.detail {
        case .binary:
            return [.note("\(sizes) (binary — not line-diffed)")]
        case let .tooLarge(baseLines, comparedLines, limit):
            return [.note("\(sizes) — \(baseLines) → \(comparedLines) lines, too large to line-diff (limit \(limit))")]
        case let .lines(added, removed):
            return [.note(sizes)]
                + removed.map { .bodyLine(added: false, text: $0) }
                + added.map { .bodyLine(added: true, text: $0) }
        }
    }

    // MARK: - Presentation

    @ViewBuilder
    private func section(_ title: String, rows: [Row]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: LoomTheme.Space.xxs) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(rows) { row in
                    switch row {
                    case let .change(label, change):
                        Text("\(label): \(change.base ?? "(absent)") → \(change.compared ?? "(absent)")")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    case let .note(text):
                        Text(text)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    case let .bodyLine(added, text):
                        // The sign carries the meaning; the tint only reinforces it,
                        // so this reads the same without color (DESIGN.md).
                        Text("\(added ? "+" : "−") \(text)")
                            .font(.callout.monospaced())
                            .foregroundStyle(added ? Color.green : Color.red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

private extension FlowComparison.ValueChange where Value == String {
    var strings: (base: String?, compared: String?) { (base, compared) }
}

private extension FlowComparison.ValueChange where Value == Int {
    var strings: (base: String?, compared: String?) { (base.map(String.init), compared.map(String.init)) }
}
