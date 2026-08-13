import Foundation

/// Which parts of a raw HTTP message's **head** carry a colour, and where.
///
/// A Raw pane is a wall of monospaced grey, and the thing being looked for in it
/// is almost always one header among thirty. Highlighting is the cheapest way to
/// make that a glance — and this is an *editor* surface, which is the one place
/// DESIGN.md's "colour is status, not decoration" already grants an exception
/// (the JSON body view has had syntax colours since it was written).
///
/// Two rules keep it from becoming decoration:
///
/// - **The head only.** Everything after the first blank line is the body and
///   stays plain: it has its own highlighting when it is JSON, and tinting
///   arbitrary payload text would be inventing meaning. It also bounds the work —
///   the head is a few hundred bytes of a payload that may be megabytes, so this
///   never scales with the body.
/// - **The same token as everywhere else.** A method is `LoomTheme.methodColor`
///   and a status is `LoomTheme.statusColor`, the functions the table's dot, the
///   method column and the badges already use. Two renderings of one fact
///   disagreeing is the bug DESIGN.md § inspector-parity exists to prevent, and a
///   Raw pane inventing its own red would be exactly that.
///
/// Pure and index-based so both raw views can share it: the SwiftUI one builds an
/// `AttributedString`, the `NSTextView` one adds attributes over `NSRange`s, and
/// neither re-derives what a header name is.
enum HTTPHeadHighlight {
    enum Role: Equatable {
        /// The request method — coloured by which methods change server state.
        case method(String)
        /// The response status code.
        case status(Int)
        /// A header's name, up to but not including the `:`.
        case headerName
    }

    struct Span: Equatable {
        let range: Range<String.Index>
        let role: Role
    }

    /// Head lines scanned at most. A well-formed message ends its head with a
    /// blank line, so this only bites on something malformed — an imported HAR
    /// with no separator, a truncated capture — where the alternative is walking a
    /// multi-megabyte body looking for a colon.
    static let maxHeadLines = 200

    static func spans(in text: String) -> [Span] {
        var spans: [Span] = []
        var lineStart = text.startIndex
        var lineNumber = 0

        while lineStart < text.endIndex, lineNumber < maxHeadLines {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart ..< lineEnd]
            // The blank line ends the head. Everything past it is the body.
            if line.isEmpty { break }

            if lineNumber == 0 {
                if let span = startLineSpan(line) { spans.append(span) }
            } else if let colon = line.firstIndex(of: ":"), colon > line.startIndex {
                spans.append(Span(range: line.startIndex ..< colon, role: .headerName))
            }

            guard lineEnd < text.endIndex else { break }
            lineStart = text.index(after: lineEnd)
            lineNumber += 1
        }
        return spans
    }

    /// The first line is either a request (`GET https://…`) or a response
    /// (`HTTP 200`), in the shapes `RequestPane.rawText` / `ResponsePane.rawText`
    /// write. Anything else is left plain rather than guessed at.
    private static func startLineSpan(_ line: Substring) -> Span? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let head = line[line.startIndex ..< space]
        if head == "HTTP" {
            let rest = line[line.index(after: space)...]
            let codeEnd = rest.firstIndex(of: " ") ?? rest.endIndex
            guard let code = Int(rest[rest.startIndex ..< codeEnd]) else { return nil }
            return Span(range: rest.startIndex ..< codeEnd, role: .status(code))
        }
        // A method is an uppercase token; anything else on line one is not one.
        guard !head.isEmpty, head.allSatisfy({ $0.isUppercase || $0 == "-" }) else { return nil }
        return Span(range: line.startIndex ..< space, role: .method(String(head)))
    }
}
