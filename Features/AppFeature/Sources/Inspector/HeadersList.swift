import LoomSharedModels
import SwiftUI

/// Headers as an aligned two-column Key/Value pane (`KeyValuePane`, shared with the
/// cookies and query panes so the three can't drift apart), followed by the trailer
/// section when the message carried one.
///
/// Trailers share this tab rather than getting their own. A tab that is empty for
/// every exchange but gRPC would be a permanent piece of dead chrome, and the thing
/// an operator actually wants — `grpc-status` next to the headers that framed it —
/// is one scroll rather than one more click. The heading only appears when there is
/// a section to head, so an ordinary response looks exactly as it did.
///
/// The section heading and the column captions are **lines of the same document**,
/// not views around it: the pane is one text view so that a drag can select a name
/// and its value together (see `KeyValueTextView`), and anything drawn outside it
/// would be the one part of the pane that selection could not reach.
struct HeadersList: View {
    let headers: [HeaderPair]
    /// Nil when the message had no trailer section at all, which is almost every
    /// message. An empty-but-present section is still shown: "the origin sent
    /// trailers and they were empty" is a fact worth being able to see.
    var trailers: [HeaderPair]?
    /// In-pane find. Matching rows are washed; Enter / chevrons step `1/N` and
    /// scroll the current one into view.
    var find: InspectorFind = InspectorFind()

    var body: some View {
        if headers.isEmpty && trailers == nil {
            Scrolled { Text("No headers").foregroundStyle(.secondary) }
        } else {
            KeyValuePane(lines: lines, find: find)
        }
    }

    private var lines: [KeyValueLine] {
        var lines: [KeyValueLine] = []
        if headers.isEmpty {
            lines.append(.note("No headers"))
        } else {
            lines.append(.captions(key: "Key", value: "Value"))
            lines += headers.map { .pair(name: $0.name, value: $0.value) }
        }
        if let trailers {
            lines.append(.section("Trailers"))
            lines += trailers.isEmpty
                ? [.note("Empty trailer section")]
                : trailers.map { .pair(name: $0.name, value: $0.value) }
        }
        return lines
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
}
