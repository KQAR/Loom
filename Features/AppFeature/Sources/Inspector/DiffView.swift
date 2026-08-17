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
                        // "Identical" is only as strong as what was captured: a
                        // capped body means the bytes past the cap were never
                        // compared, and saying "identical" flat would overclaim.
                        Text(comparison.isPartial
                            ? "Identical as far as Loom recorded — a body was capture-capped, so the bytes past the cap were never compared."
                            : "Identical — same request, same response.")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
                            section("Record", rows: recordRows(comparison))
                            section("Request", rows: requestRows(comparison.request))
                            section("Response", rows: responseRows(comparison.response))
                            section("WebSocket", rows: webSocketRows(comparison.webSocket))
                            section("Error", rows: errorRows(comparison))
                        }
                    }
                }
            }
            .task(id: key) {
                let result = await Self.compare(base: original, compared: replayed)
                guard !Task.isCancelled else { return }
                comparison = result
            }
        }
    }

    /// `@concurrent` rather than `Task.detached` (see the longer note in
    /// `RawTab.build`): the diff has to leave the main actor, but a detached task
    /// leaves the *task tree* as well, so switching rows cancelled this `.task`
    /// while the LCS walk ran on regardless — and `await …value` waited for it.
    /// The `Task.isCancelled` check at the call site is only honest with this.
    ///
    /// A wrapper rather than `@concurrent` on `FlowComparison.compare` itself:
    /// that is public API in SharedModels, shared with the MCP `diff_flows` path
    /// and with embedders, and one view's execution context is no reason to make
    /// every caller `await`.
    @concurrent private static func compare(base: Flow, compared: Flow) async -> FlowComparison {
        FlowComparison.compare(base: base, compared: compared)
    }

    // MARK: - Rows

    /// One line of the diff. Modelled rather than pre-formatted so added/removed
    /// body lines can carry their own styling.
    ///
    /// Deliberately **not** `Identifiable`: an id derived from the content collides
    /// the moment a body diff drops two identical lines (`  },`, `}`, a blank line —
    /// the ordinary shape of a JSON diff), and a `ForEach` over colliding ids drops
    /// rows and logs about it. `section` enumerates instead, so position is the id.
    private enum Row {
        case change(label: String, change: (base: String?, compared: String?))
        case note(String)
        case bodyLine(added: Bool, text: String)
    }

    private func recordRows(_ comparison: FlowComparison) -> [Row] {
        var rows: [Row] = []
        if let kind = comparison.recordKind {
            rows.append(.change(label: "type", change: kind.strings))
        }
        if let tunnel = comparison.tunnel {
            rows.append(.change(label: "tunnel", change: tunnel.strings))
        }
        return rows
    }

    private func errorRows(_ comparison: FlowComparison) -> [Row] {
        var rows: [Row] = []
        if let error = comparison.error {
            rows.append(.change(label: "error", change: error.strings))
        }
        if let code = comparison.errorCode {
            rows.append(.change(label: "kind", change: code.strings))
        }
        if let detail = comparison.errorDetail {
            rows.append(.change(label: "detail", change: detail.strings))
        }
        return rows
    }

    private func requestRows(_ request: FlowComparison.MessageComparison) -> [Row] {
        var rows: [Row] = []
        if let method = request.method { rows.append(.change(label: "method", change: method.strings)) }
        if let url = request.url { rows.append(.change(label: "url", change: url.strings)) }
        rows.append(contentsOf: headerRows(request.headers))
        rows.append(contentsOf: headerRows(request.trailers, kind: "trailer"))
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
        rows.append(contentsOf: headerRows(response.trailers, kind: "trailer"))
        rows.append(contentsOf: bodyRows(response.body))
        return rows
    }

    /// `kind` labels the row, because a field that moved between the head and the
    /// trailers reads as two unrelated changes otherwise.
    private func headerRows(_ headers: [FlowComparison.HeaderChange], kind: String = "header") -> [Row] {
        headers.map { header in
            .change(
                label: "\(kind) \(header.name)",
                change: (header.base?.joined(separator: ", "), header.compared?.joined(separator: ", "))
            )
        }
    }

    private func bodyRows(_ body: FlowComparison.BodyComparison?) -> [Row] {
        guard let body else { return [] }
        let sizes = "body: \(body.baseBytes) → \(body.comparedBytes) bytes"
        // A capped prefix has to say so next to the numbers: those bytes are not
        // the payload, and the diff below them covers only the prefix.
        var rows: [Row] = []
        if body.isTruncated {
            let wire = { (recorded: Int, onWire: Int?) in onWire.map { "\($0)" } ?? "\(recorded) (whole)" }
            rows.append(.note(
                "capture-capped — on the wire: \(wire(body.baseBytes, body.baseWireBytes)) → "
                    + "\(wire(body.comparedBytes, body.comparedWireBytes)) bytes; "
                    + "the diff below covers the recorded prefix only"
            ))
        }
        switch body.detail {
        case .binary:
            rows.append(.note("\(sizes) (binary — not line-diffed)"))
        case .tailNotCaptured:
            rows.append(.note("\(sizes) — recorded prefixes are identical; the bytes past the cap were never compared"))
        case let .tooLarge(baseLines, comparedLines, reason):
            rows.append(.note(
                "\(sizes) — \(baseLines) → \(comparedLines) lines, not line-diffed (\(reason.explanation))"
            ))
        case let .lines(added, removed):
            rows.append(.note(sizes))
            rows += removed.map { .bodyLine(added: false, text: $0) }
            rows += added.map { .bodyLine(added: true, text: $0) }
        }
        return rows
    }

    private func webSocketRows(_ webSocket: FlowComparison.WebSocketComparison) -> [Row] {
        if let presence = webSocket.presence {
            return [.note((presence.compared ?? false)
                ? "the replay is a WebSocket; the original isn't"
                : "the original is a WebSocket; the replay isn't")]
        }
        var rows: [Row] = []
        if let count = webSocket.messageCount {
            rows.append(.change(label: "frames", change: count.strings))
        }
        if let index = webSocket.firstDifferingMessage {
            rows.append(.note("frame logs first differ at frame \(index)"))
        }
        if let dropped = webSocket.droppedMessages {
            rows.append(.change(label: "frames not recorded", change: dropped.strings))
        }
        if let error = webSocket.captureError {
            rows.append(.change(label: "capture stopped", change: error.strings))
        }
        return rows
    }

    // MARK: - Presentation

    /// `LazyVStack`, because a body diff is a collection that grows: up to
    /// `FlowComparison.maxDiffLines` added plus as many removed, per section, and
    /// this view sits inside the inspector's `ScrollView`. Rendering all of them
    /// eagerly is the pattern AGENTS.md rules out for exactly this reason.
    ///
    /// Enumerated rather than `ForEach(rows)`: position is the identity (see `Row`).
    @ViewBuilder
    private func section(_ title: String, rows: [Row]) -> some View {
        if !rows.isEmpty {
            LazyVStack(alignment: .leading, spacing: LoomTheme.Space.xxs) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
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
                            .foregroundStyle(added ? LoomTheme.Palette.success : LoomTheme.Palette.error)
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

private extension FlowComparison.ValueChange where Value == Flow.RecordKind {
    var strings: (base: String?, compared: String?) {
        (base?.rawValue, compared?.rawValue)
    }
}

private extension FlowComparison.ValueChange where Value == FlowError.Code {
    var strings: (base: String?, compared: String?) {
        (base?.rawValue, compared?.rawValue)
    }
}

private extension FlowComparison.ValueChange where Value == Flow.TunnelDiagnostic? {
    var strings: (base: String?, compared: String?) {
        func describe(_ value: Flow.TunnelDiagnostic?) -> String? {
            value.map {
                let reason = $0.reason?.rawValue ?? "legacyUnknown"
                return "\($0.host):\($0.port) — \(reason)"
                    + ($0.detail.map { " — \($0)" } ?? "")
            }
        }
        return (describe(base ?? nil), describe(compared ?? nil))
    }
}
