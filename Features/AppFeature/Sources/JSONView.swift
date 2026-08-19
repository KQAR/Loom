import SwiftUI

/// An order-preserving JSON value. `Foundation`'s JSONSerialization loses object
/// key order, which a debugger shouldn't — so we parse into this instead.
indirect enum JSONValue: Equatable {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    var isContainer: Bool {
        switch self {
        case .object, .array: return true
        default: return false
        }
    }

    /// Parse `data` as JSON, preserving key order. Returns nil on any malformed
    /// input so the caller can fall back to a raw-text view.
    static func parse(_ data: Data) -> JSONValue? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var parser = JSONParser(text)
        return parser.parseTopLevel()
    }

    /// Pretty-print back to JSON text, preserving key order (unlike
    /// `JSONSerialization`, which would reshuffle object keys). Used by the rule
    /// editor's Format action so reformatting never reorders a mock body.
    func prettyPrinted(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let childPad = String(repeating: "  ", count: indent + 1)
        switch self {
        case let .object(pairs):
            guard !pairs.isEmpty else { return "{}" }
            let body = pairs.map { key, value in
                "\(childPad)\(Self.encodeString(key)): \(value.prettyPrinted(indent: indent + 1))"
            }.joined(separator: ",\n")
            return "{\n\(body)\n\(pad)}"
        case let .array(items):
            guard !items.isEmpty else { return "[]" }
            let body = items.map { "\(childPad)\($0.prettyPrinted(indent: indent + 1))" }
                .joined(separator: ",\n")
            return "[\n\(body)\n\(pad)]"
        case let .string(s): return Self.encodeString(s)
        case let .number(n): return n
        case let .bool(b): return b ? "true" : "false"
        case .null: return "null"
        }
    }

    private static func encodeString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.array(a), .array(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }
}

/// Small recursive-descent JSON parser. Handles the full grammar (nested
/// containers, string escapes incl. \uXXXX, numbers, keywords); anything it can't
/// parse yields nil and the UI shows raw text instead.
private struct JSONParser {
    private let chars: [Character]
    private var i = 0

    init(_ text: String) { chars = Array(text) }

    mutating func parseTopLevel() -> JSONValue? {
        skipWhitespace()
        guard let value = parseValue() else { return nil }
        skipWhitespace()
        return i == chars.count ? value : nil
    }

    private mutating func skipWhitespace() {
        while i < chars.count, chars[i] == " " || chars[i] == "\n" || chars[i] == "\t" || chars[i] == "\r" {
            i += 1
        }
    }

    private func peek() -> Character? { i < chars.count ? chars[i] : nil }

    private mutating func parseValue() -> JSONValue? {
        skipWhitespace()
        switch peek() {
        case "{": return parseObject()
        case "[": return parseArray()
        case "\"": return parseString().map { .string($0) }
        case "t", "f": return parseKeyword()
        case "n": return match("null") ? .null : nil
        default: return parseNumber()
        }
    }

    private mutating func parseObject() -> JSONValue? {
        i += 1 // consume {
        var pairs: [(String, JSONValue)] = []
        skipWhitespace()
        if peek() == "}" { i += 1; return .object(pairs) }
        while true {
            skipWhitespace()
            guard peek() == "\"", let key = parseString() else { return nil }
            skipWhitespace()
            guard peek() == ":" else { return nil }
            i += 1
            guard let value = parseValue() else { return nil }
            pairs.append((key, value))
            skipWhitespace()
            switch peek() {
            case ",": i += 1
            case "}": i += 1; return .object(pairs)
            default: return nil
            }
        }
    }

    private mutating func parseArray() -> JSONValue? {
        i += 1 // consume [
        var items: [JSONValue] = []
        skipWhitespace()
        if peek() == "]" { i += 1; return .array(items) }
        while true {
            guard let value = parseValue() else { return nil }
            items.append(value)
            skipWhitespace()
            switch peek() {
            case ",": i += 1
            case "]": i += 1; return .array(items)
            default: return nil
            }
        }
    }

    private mutating func parseString() -> String? {
        guard peek() == "\"" else { return nil }
        i += 1
        var result = ""
        while i < chars.count {
            let c = chars[i]; i += 1
            if c == "\"" { return result }
            if c == "\\" {
                guard i < chars.count else { return nil }
                let esc = chars[i]; i += 1
                switch esc {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "u":
                    guard i + 4 <= chars.count,
                          let code = UInt32(String(chars[i ..< i + 4]), radix: 16),
                          let scalar = Unicode.Scalar(code) else { return nil }
                    i += 4
                    result.append(Character(scalar))
                default: return nil
                }
            } else {
                result.append(c)
            }
        }
        return nil
    }

    private mutating func parseKeyword() -> JSONValue? {
        if match("true") { return .bool(true) }
        if match("false") { return .bool(false) }
        return nil
    }

    private mutating func match(_ keyword: String) -> Bool {
        let k = Array(keyword)
        guard i + k.count <= chars.count, Array(chars[i ..< i + k.count]) == k else { return false }
        i += k.count
        return true
    }

    private mutating func parseNumber() -> JSONValue? {
        let start = i
        while i < chars.count, "0123456789+-.eE".contains(chars[i]) { i += 1 }
        guard i > start else { return nil }
        let text = String(chars[start ..< i])
        guard Double(text) != nil else { return nil }
        return .number(text)
    }
}

// MARK: - View

/// A collapsible, syntax-highlighted JSON tree. Objects/arrays are disclosure
/// nodes (chevron toggles, collapsed shows `{…} n`); leaves are colored by type.
/// Editor-style syntax colors are a deliberate exception to "color only for
/// status" — this is a code viewer.
struct JSONView: View {
    let value: JSONValue
    /// In-pane find hits, walked **once** by whoever owns the body (`BodyView`)
    /// and handed down. Empty keeps the default expansion (depth < 2); a
    /// populated index highlights matching lines and *opens* their ancestors —
    /// it never collapses a node that was already open.
    ///
    /// Computed here it was walked twice per render — once for the tree, once
    /// again for the `1/N` the action cluster shows — on every keystroke.
    var index = JSONFindIndex()
    /// 0-based current hit among matching lines. The current line uses the
    /// darker wash; `ScrollViewReader` scrolls it into the pane's viewport.
    var findIndex: Int = 0

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 1) {
                JSONNode(key: nil, value: value, depth: 0, path: [])
                    .id(JSONFindLineID(path: []))
            }
            .font(.callout.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.jsonFindMatched, index.matched)
            .environment(\.jsonFindExpand, index.expand)
            .environment(\.jsonFindCurrent, index.path(at: findIndex))
            .task(id: index.path(at: findIndex)) {
                guard let path = index.path(at: findIndex) else { return }
                await Task.yield()
                proxy.scrollTo(JSONFindLineID(path: path), anchor: .center)
            }
        }
    }
}

/// Identity for one JSON tree line, so `ScrollViewProxy.scrollTo` can bring
/// the current find hit into the enclosing `Scrolled` viewport.
private struct JSONFindLineID: Hashable {
    let path: [Int]
}

private enum JSONFindMatchedKey: EnvironmentKey {
    static let defaultValue: Set<[Int]> = []
}

private enum JSONFindExpandKey: EnvironmentKey {
    static let defaultValue: Set<[Int]> = []
}

private enum JSONFindCurrentKey: EnvironmentKey {
    static let defaultValue: [Int]? = nil
}

extension EnvironmentValues {
    fileprivate var jsonFindMatched: Set<[Int]> {
        get { self[JSONFindMatchedKey.self] }
        set { self[JSONFindMatchedKey.self] = newValue }
    }

    fileprivate var jsonFindExpand: Set<[Int]> {
        get { self[JSONFindExpandKey.self] }
        set { self[JSONFindExpandKey.self] = newValue }
    }

    fileprivate var jsonFindCurrent: [Int]? {
        get { self[JSONFindCurrentKey.self] }
        set { self[JSONFindCurrentKey.self] = newValue }
    }
}

private struct JSONNode: View {
    let key: String?
    let value: JSONValue
    let depth: Int
    let path: [Int]
    @State private var userExpanded: Bool?
    @State private var textOverride: String?
    @Environment(\.jsonFindMatched) private var findMatched
    @Environment(\.jsonFindExpand) private var findExpand
    @Environment(\.jsonFindCurrent) private var findCurrent

    /// A dedicated left gutter that holds every disclosure chevron in one column
    /// at the far left, and per-level indentation applied only to the content —
    /// so the chevron never sits flush against the key/value.
    private static let gutter: CGFloat = 18
    private static let indentUnit: CGFloat = 14
    private static let contentGap: CGFloat = 4

    /// Search may open a collapsed ancestor so the hit is visible. It must
    /// not close anything the reader already had open — `findExpand` is OR,
    /// never a replacement for the default / user expansion.
    private var isExpanded: Bool {
        (userExpanded ?? (depth < 2)) || findExpand.contains(path)
    }

    /// Whether *this* line is a hit — a set lookup, not a re-match. The node
    /// used to build a `NeedleMatcher` from the needle and run
    /// `InspectorFindMatch.lineMatches` itself, i.e. one allocation and one
    /// scan per visible node per render, which is the "prepare a filter once,
    /// not per row" rule inverted.
    private var lineMatches: Bool { findMatched.contains(path) }

    var body: some View {
        switch value {
        case let .object(pairs):
            container(count: pairs.count, open: "{", close: "}") {
                // `Array(...)` is required, not a leftover: EnumeratedSequence only
                // conforms to RandomAccessCollection on macOS 26+, and this ships to 14.
                ForEach(Array(pairs.enumerated()), id: \.offset) { i, pair in
                    JSONNode(key: pair.0, value: pair.1, depth: depth + 1, path: path + [i])
                        .id(JSONFindLineID(path: path + [i]))
                }
            }
        case let .array(items):
            container(count: items.count, open: "[", close: "]") {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    JSONNode(key: nil, value: item, depth: depth + 1, path: path + [i])
                        .id(JSONFindLineID(path: path + [i]))
                }
            }
        default:
            leaf
        }
    }

    /// Fixed-width chevron gutter (far left). `expanded == nil` renders an empty
    /// slot so leaves and closing braces align under the same column.
    private func gutterChevron(_ expanded: Bool?) -> some View {
        ZStack {
            if let expanded {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(LoomTheme.Icon.tiny)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.gutter, alignment: .center)
    }

    private func indent(_ depth: Int) -> some View {
        Color.clear.frame(width: CGFloat(depth) * Self.indentUnit + Self.contentGap, height: 1)
    }

    @ViewBuilder
    private func container<Children: View>(
        count: Int, open: String, close: String, @ViewBuilder children: () -> Children
    ) -> some View {
        // Lazy, or expanding one 5000-element array instantiates 5000 child nodes
        // (each with its own @State) in one update pass and re-diffs them on every
        // inspector re-render. Lazy creation bounds that to the visible screenful;
        // `Scrolled`'s ScrollView provides the viewport.
        LazyVStack(alignment: .leading, spacing: 1) {
            Button {
                userExpanded = !isExpanded
            } label: {
                HStack(spacing: 0) {
                    gutterChevron(isExpanded)
                    indent(depth)
                    if isExpanded {
                        keyPrefix + Text(open).foregroundStyle(.secondary)
                    } else {
                        keyPrefix
                            + Text("\(open)…\(close)").foregroundStyle(.secondary)
                            // `verbatim:` — a LocalizedStringKey would group the digits,
                            // so a 1234-element array collapsed to "1,234" (the same
                            // trap the panel's port display already documents).
                            + Text(verbatim: "  \(count)").foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .background { findWash }
            }
            .buttonStyle(.plain)

            if isExpanded {
                children()
                HStack(spacing: 0) {
                    gutterChevron(nil)
                    indent(depth)
                    Text(close).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var leaf: some View {
        HStack(alignment: .top, spacing: 0) {
            gutterChevron(nil)
            indent(depth)
            Group {
                if let textOverride {
                    Text(textOverride)
                } else {
                    keyPrefix + valueText
                }
            }
            .textSelection(.enabled)
            .overlay {
                WireTextHostOverlay(
                    displayed: textOverride ?? leafSource,
                    hasOverride: textOverride != nil,
                    onDecode: { textOverride = $0 },
                    onShowOriginal: { textOverride = nil }
                )
            }
            Spacer(minLength: 0)
        }
        .background { findWash }
        .onChange(of: leafSource) { textOverride = nil }
    }

    @ViewBuilder private var findWash: some View {
        if lineMatches {
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    findCurrent == path
                        ? InspectorText.FindWash.current
                        : InspectorText.FindWash.other
                )
        }
    }

    private var leafSource: String {
        let prefix = key.map { "\"\($0)\": " } ?? ""
        switch value {
        case let .string(s): return prefix + "\"\(s)\""
        case let .number(n): return prefix + n
        case let .bool(b): return prefix + (b ? "true" : "false")
        case .null: return prefix + "null"
        default: return prefix
        }
    }

    private var keyPrefix: Text {
        guard let key else { return Text("") }
        return Text("\"\(key)\"").foregroundStyle(Color(nsColor: .labelColor))
            + Text(": ").foregroundStyle(.secondary)
    }

    private var valueText: Text {
        switch value {
        case let .string(s): return Text("\"\(s)\"").foregroundStyle(LoomTheme.Palette.Syntax.string)
        case let .number(n): return Text(n).foregroundStyle(LoomTheme.Palette.Syntax.number)
        case let .bool(b): return Text(b ? "true" : "false").foregroundStyle(LoomTheme.Palette.Syntax.bool)
        case .null: return Text("null").foregroundStyle(.secondary)
        default: return Text("")
        }
    }
}
