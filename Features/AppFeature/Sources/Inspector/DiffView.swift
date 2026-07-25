import LoomSharedModels
import SwiftUI

struct DiffView: View {
    let original: Flow?
    let replayed: Flow
    var body: some View {
        if let original {
            let lines = diffLines(original: original, replayed: replayed)
            if lines.isEmpty {
                Text("Identical request; response may differ.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: LoomTheme.Space.xxs) {
                    ForEach(lines, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }
                }
            }
        }
    }

    private func diffLines(original: Flow, replayed: Flow) -> [String] {
        var lines: [String] = []
        if original.request.method != replayed.request.method {
            lines.append("method: \(original.request.method) → \(replayed.request.method)")
        }
        if original.request.url != replayed.request.url {
            lines.append("url: \(original.request.url) → \(replayed.request.url)")
        }
        let originalHeaders = Dictionary(original.request.headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        let replayedHeaders = Dictionary(replayed.request.headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        for (name, value) in replayedHeaders.sorted(by: { $0.key < $1.key }) {
            if let old = originalHeaders[name] {
                if old != value { lines.append("header \(name): \(old) → \(value)") }
            } else {
                lines.append("header \(name): (added) \(value)")
            }
        }
        for name in originalHeaders.keys.sorted() where replayedHeaders[name] == nil {
            lines.append("header \(name): (removed)")
        }
        if original.request.body != replayed.request.body { lines.append("body: changed") }
        if original.statusCode != replayed.statusCode {
            lines.append("status: \(original.statusCode.map(String.init) ?? "—") → \(replayed.statusCode.map(String.init) ?? "—")")
        }
        return lines
    }
}
