import LoomSharedModels
import SwiftUI

/// Headers as an aligned two-column Key/Value table (`KeyValueGrid`, shared with the
/// cookies pane so the two can't drift apart), followed by the trailer section when
/// the message carried one.
///
/// Trailers share this tab rather than getting their own. A tab that is empty for
/// every exchange but gRPC would be a permanent piece of dead chrome, and the thing
/// an operator actually wants — `grpc-status` next to the headers that framed it —
/// is one scroll rather than one more click. The heading only appears when there is
/// a section to head, so an ordinary response looks exactly as it did.
struct HeadersList: View {
    let headers: [HeaderPair]
    /// Nil when the message had no trailer section at all, which is almost every
    /// message. An empty-but-present section is still shown: "the origin sent
    /// trailers and they were empty" is a fact worth being able to see.
    var trailers: [HeaderPair]?
    /// In-pane find. Matching rows are washed; Enter / chevrons step `1/N` and
    /// scroll the current one into the enclosing `Scrolled` viewport.
    var find: InspectorFind = InspectorFind()

    var body: some View {
        let current = currentID
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: LoomTheme.Space.md) {
                if headers.isEmpty {
                    Text("No headers").foregroundStyle(.secondary)
                } else {
                    grid(headers, section: .headers, current: current)
                }
                if let trailers {
                    Text("Trailers")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if trailers.isEmpty {
                        Text("Empty trailer section").foregroundStyle(.secondary)
                    } else {
                        grid(trailers, section: .trailers, current: current)
                    }
                }
            }
            .preference(key: InspectorFindReportKey.self, value: findReport)
            .task(id: current) {
                guard let current else { return }
                await Task.yield()
                proxy.scrollTo(current, anchor: .center)
            }
        }
    }

    /// Wire-shaped `Name: Value` lines, headers then trailers. What Copy writes.
    static func copyText(headers: [HeaderPair], trailers: [HeaderPair]?) -> String {
        var lines = headers.map { "\($0.name): \($0.value)" }
        if let trailers, !trailers.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines += trailers.map { "\($0.name): \($0.value)" }
        }
        return lines.joined(separator: "\n")
    }

    private func grid(
        _ pairs: [HeaderPair], section: HeaderRowID.Section, current: HeaderRowID?
    ) -> some View {
        KeyValueGrid {
            ForEach(pairs.indices, id: \.self) { i in
                let id = HeaderRowID(section: section, index: i)
                let isMatch = rowMatches(pairs[i])
                GridRow(alignment: .firstTextBaseline) {
                    Text(pairs[i].name)
                        // The same violet the Raw pane tints a header name
                        // with — one fact, one token (DESIGN.md §
                        // inspector-parity). It also gives this grid the thing
                        // it was missing: a scan column that is visibly a
                        // different kind of thing from the values beside it.
                        .foregroundStyle(LoomTheme.Palette.Syntax.name)
                        .textSelection(.enabled)
                        .background { KeyValueFindWash.fill(isMatch: isMatch, isCurrent: current == id) }
                    HeaderValueText(value: pairs[i].value)
                        .background { KeyValueFindWash.fill(isMatch: isMatch, isCurrent: current == id) }
                }
                .font(.callout.monospaced())
                .id(id)
            }
        }
    }

    private var matchIDs: [HeaderRowID] {
        guard find.isActive else { return [] }
        let matcher = NeedleMatcher(find.trimmed)
        var ids: [HeaderRowID] = []
        for (i, pair) in headers.enumerated() where Self.matches(pair, matcher: matcher) {
            ids.append(HeaderRowID(section: .headers, index: i))
        }
        if let trailers {
            for (i, pair) in trailers.enumerated() where Self.matches(pair, matcher: matcher) {
                ids.append(HeaderRowID(section: .trailers, index: i))
            }
        }
        return ids
    }

    private var currentID: HeaderRowID? {
        let ids = matchIDs
        return ids.indices.contains(find.currentIndex) ? ids[find.currentIndex] : nil
    }

    private var findReport: InspectorFindReport {
        guard find.isActive else { return .empty }
        return InspectorFindReport(matchCount: matchIDs.count)
    }

    private func rowMatches(_ pair: HeaderPair) -> Bool {
        guard find.isActive else { return false }
        return InspectorFindMatch.fieldsMatch([pair.name, pair.value], needle: find.trimmed)
    }

    private static func matches(_ pair: HeaderPair, matcher: NeedleMatcher) -> Bool {
        InspectorFindMatch.rowMatches([pair.name, pair.value], matcher: matcher)
    }
}

/// One header or trailer row, so find can step across both sections as one `1/N`.
private struct HeaderRowID: Hashable {
    enum Section { case headers, trailers }
    var section: Section
    var index: Int
}

/// A header value that can be percent-decoded in place from the context menu.
///
/// The capture is not mutated: decode is a reading of the displayed string, and
/// Show Original restores the bytes that arrived. Applying decode to *what is
/// showing* (not always the raw capture) is what lets `%2520` be decoded twice.
private struct HeaderValueText: View {
    let value: String
    @State private var override: String?

    private var displayed: String { override ?? value }

    var body: some View {
        Text(displayed)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .overlay {
                WireTextHostOverlay(
                    displayed: displayed,
                    hasOverride: override != nil,
                    onDecode: { override = $0 },
                    onShowOriginal: { override = nil }
                )
            }
            .onChange(of: value) { override = nil }
    }
}
