import AppKit
import LoomSharedModels
import SwiftUI

/// One rendered row of a key/value pane, in the order it is shown.
enum KeyValueLine: Equatable, Hashable, Identifiable {
    /// `secondary` is the dimmer continuation a value may carry — a `Set-Cookie`'s
    /// attributes. `dimValue` is for a value that is a *statement about* the value
    /// rather than one — the query pane's "—" for a flag parameter, which is not an
    /// empty string.
    case pair(name: String, value: String, secondary: String = "", dimValue: Bool = false)
    case section(String)
    /// The `Key`/`Value` captions above a block.
    case captions(key: String, value: String)
    /// A dimmer aside — "No headers", "Empty trailer section". A statement *about*
    /// the block rather than a row of it, so find never matches it.
    case note(String)

    var id: Self { self }

    var searchableFields: [String] {
        switch self {
        case let .pair(name, value, secondary, _): [name, value, secondary]
        case .section, .captions, .note: []
        }
    }

    /// `Name: Value` for the clipboard and for the detail popover's Copy.
    var copyText: String {
        switch self {
        case let .pair(name, value, secondary, _):
            secondary.isEmpty ? "\(name): \(value)" : "\(name): \(value); \(secondary)"
        case let .section(text), let .note(text): text
        case let .captions(key, value): "\(key)\t\(value)"
        }
    }
}

/// The inspector's key/value pane — Headers, Cookies and Query all render through
/// here, which is what keeps "the three read alike" true without anyone copying
/// spacing across.
///
/// Three rules, and each one is what the previous attempt got wrong:
///
/// - **The key column is a fraction of the pane, not the widest key.** Sizing to the
///   content means one `content-security-policy` sets the column for every row that
///   follows, so on a narrow inspector every value is squeezed into what is left.
///   `keyColumn` is 30 % of the pane, clamped, which is what DevTools and Firefox's
///   network panels both do.
/// - **A key wraps inside its column; it is never truncated.** A header name is the
///   thing being scanned for — an elided one is a row that cannot be identified.
/// - **A value is one line.** Wrapping values makes row height a function of content,
///   so a JWT or a CSP pushes everything else off screen and the pane stops being a
///   list. The full text is one click away in the detail popover, which is also where
///   selecting and copying it happens.
struct KeyValuePane: View {
    let lines: [KeyValueLine]
    var find: InspectorFind = InspectorFind()

    /// Fraction of the pane the key column takes, and the bounds it is held inside.
    /// The floor keeps short names from collapsing to nothing on a narrow inspector;
    /// the ceiling keeps a wide window from spending half of itself on `accept`.
    private static let keyFraction: CGFloat = 0.3
    private static let keyColumnBounds: ClosedRange<CGFloat> = 90...260

    /// Which row's detail is open, by index. **By index, not by value**: two rows
    /// can hold the same pair (a repeated `set-cookie`, two identical `accept`
    /// headers), and a popover bound to the value presents on every row that equals
    /// it — which is what made the arrow point at the wrong row.
    @State private var opened: Int?

    var body: some View {
        // One scan per render, shared by the wash, the `1/N` and the scroll target.
        let matches = matchIndices
        let matched = Set(matches)
        let current = matches.indices.contains(find.currentIndex) ? matches[find.currentIndex] : nil
        GeometryReader { proxy in
            let keyColumn = min(
                max(proxy.size.width * Self.keyFraction, Self.keyColumnBounds.lowerBound),
                Self.keyColumnBounds.upperBound
            )
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: LoomTheme.Space.xxs) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            row(line, at: index, keyColumn: keyColumn,
                                isMatch: matched.contains(index), isCurrent: current == index)
                                .id(index)
                        }
                    }
                    .padding(LoomTheme.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .task(id: current) {
                    guard let current else { return }
                    await Task.yield()
                    scroll.scrollTo(current, anchor: .center)
                }
            }
        }
        .preference(
            key: InspectorFindReportKey.self,
            value: find.isActive ? InspectorFindReport(matchCount: matches.count) : .empty
        )
    }

    @ViewBuilder
    private func row(
        _ line: KeyValueLine, at index: Int, keyColumn: CGFloat, isMatch: Bool, isCurrent: Bool
    ) -> some View {
        switch line {
        case let .pair(name, value, secondary, dimValue):
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: LoomTheme.Space.xs) {
                    Text(name)
                        // The same violet the Raw pane tints a header name with — one
                        // fact, one token (DESIGN.md § inspector-parity).
                        .foregroundStyle(LoomTheme.Palette.Syntax.name)
                        // Wraps rather than truncating: the name is what a reader
                        // scans for, and an elided one identifies nothing.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: keyColumn, alignment: .leading)
                    Text(value)
                        .foregroundStyle(dimValue ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !secondary.isEmpty {
                    Text(secondary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, keyColumn + LoomTheme.Space.xs)
                }
            }
            .font(.callout.monospaced())
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // The open row stays marked while its popover is up: the popover can
                // cover a lot of the pane, and without this there is nothing saying
                // which row it belongs to once the arrow is behind it.
                KeyValueRowBackground(
                    isSelected: opened == index, isMatch: isMatch, isCurrent: isCurrent
                )
            }
            .contentShape(Rectangle())
            // A single click opens the row, because the row deliberately shows less
            // than it holds — one line of a value that may be a 4 KB CSP. The popover
            // is where the whole thing is readable, selectable and copyable.
            .onTapGesture { opened = index }
            // Bound per row, so exactly one popover is presented and its arrow
            // anchors to the row that was clicked.
            .popover(
                isPresented: Binding(
                    get: { opened == index },
                    set: { if !$0, opened == index { opened = nil } }
                ),
                arrowEdge: .trailing
            ) {
                KeyValueDetail(name: name, value: value, secondary: secondary)
            }
            .help("Click to open")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(name): \(value)")

        case let .section(title):
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, LoomTheme.Space.md)

        case let .captions(key, value):
            HStack(alignment: .firstTextBaseline, spacing: LoomTheme.Space.xs) {
                Text(key).frame(width: keyColumn, alignment: .leading)
                Text(value)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, LoomTheme.Space.xxs)

        case let .note(text):
            Text(text).foregroundStyle(.secondary)
        }
    }

    private var matchIndices: [Int] {
        guard find.isActive else { return [] }
        let matcher = NeedleMatcher(find.trimmed)
        return lines.indices.filter {
            InspectorFindMatch.rowMatches(lines[$0].searchableFields, matcher: matcher)
        }
    }
}

/// The whole of one pair, opened from its row: the name, the value in full, and a
/// cookie's attributes when it has them.
///
/// It exists because the row shows one line on purpose. Everything here is
/// selectable — this is the surface a value is copied *from*, which is what the
/// single-line row gives up.
///
/// **It sizes to what it holds.** A `content-length: 42` in a 460×400 sheet is mostly
/// empty box, and a 4 KB CSP in the same box is a keyhole; both were the same popover
/// before. A short value is a wrapping `Text` that the popover fits itself around, a
/// long one gets `CodeTextView` (TextKit lays out only the visible part) at a height
/// derived from how much there is to show, and the width steps up with it.
private struct KeyValueDetail: View {
    let name: String
    let value: String
    let secondary: String

    /// Past this many characters the value stops being something to read at a glance
    /// and becomes something to scroll, which is the point the two layouts swap.
    private static let longValue = 240
    private static let narrow: CGFloat = 420
    private static let wide: CGFloat = 640
    /// Bounds on the scrolling value's height. The floor stops a two-line JSON body
    /// from opening a sliver; the ceiling keeps the popover on screen.
    private static let bodyHeight: ClosedRange<CGFloat> = 120...460

    private var isLong: Bool { value.count > Self.longValue || value.contains("\n") }
    private var width: CGFloat { isLong ? Self.wide : Self.narrow }

    /// Roughly how tall the value wants to be: its own lines plus the wraps a
    /// monospaced line of `width` implies, one `NSFont.systemFontSize` line each.
    private var bodyHeight: CGFloat {
        let charactersPerLine = max(1, Int((Self.wide - LoomTheme.Space.md * 4) / 7.2))
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) {
            $0 + max(1, ($1.count + charactersPerLine - 1) / charactersPerLine)
        }
        let wanted = CGFloat(lines) * (NSFont.systemFontSize + 4) + LoomTheme.Space.md * 2
        return min(max(wanted, Self.bodyHeight.lowerBound), Self.bodyHeight.upperBound)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
            header
            Divider()
            if isLong {
                // `.zero` inset and no border: the popover already pads, so the
                // value's first character lines up under the name exactly as the
                // short layout's does. A box around it would make the long case look
                // like a different kind of thing from the short one.
                CodeTextView(text: value, identity: "kv:\(name):\(value.count)", textInset: .zero)
                    .frame(height: bodyHeight)
            } else {
                Text(value)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !secondary.isEmpty { attributes }
        }
        .padding(LoomTheme.Space.md)
        .frame(width: width)
    }

    /// Name, then what the value costs, then Copy. The size is here rather
    /// than nowhere because it is the one fact the value's own text cannot state, and
    /// it is what says whether the box below is the whole of it.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: LoomTheme.Space.xs) {
            Text(name)
                .font(.callout.monospaced().weight(.semibold))
                .foregroundStyle(LoomTheme.Palette.Syntax.name)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(ByteCountFormatter.string(fromByteCount: Int64(value.utf8.count), countStyle: .file))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer(minLength: LoomTheme.Space.sm)
            // One button, and it writes both halves. Two (value / name+value) is a
            // choice nobody arrives here to make — the value alone is a selection
            // away, which is what everything in this popover is for.
            Button { MainView.copy(copyText) } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy name and value")
        }
    }

    private var copyText: String {
        secondary.isEmpty ? "\(name): \(value)" : "\(name): \(value); \(secondary)"
    }

    /// A cookie's `Path` / `HttpOnly` / `SameSite` …, kept visually subordinate to the
    /// value they qualify rather than sharing its weight.
    private var attributes: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.xxs) {
            Text("Attributes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(secondary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row's backing: the open row's selection, or the find wash behind a match (the
/// current hit being the darker yellow). Selection wins — it is the more recent, and
/// the more deliberate, of the two things the operator did.
struct KeyValueRowBackground: View {
    var isSelected = false
    var isMatch = false
    var isCurrent = false

    var body: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: LoomTheme.Radius.sm)
                .fill(LoomTheme.Palette.accent.opacity(0.15))
                .overlay {
                    RoundedRectangle(cornerRadius: LoomTheme.Radius.sm)
                        .strokeBorder(LoomTheme.Palette.accent.opacity(0.5), lineWidth: 1)
                }
        } else if isMatch {
            RoundedRectangle(cornerRadius: 2)
                .fill(isCurrent ? InspectorText.FindWash.current : InspectorText.FindWash.other)
        }
    }
}
