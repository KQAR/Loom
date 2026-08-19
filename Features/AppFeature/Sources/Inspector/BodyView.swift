import AppKit
import SwiftUI

struct BodyView: View {
    let data: Data?
    let identity: AnyHashable
    /// Total bytes that crossed the wire when `data` is only the captured prefix
    /// (nil = complete). Drives the "this is partial" strip.
    var fullBodyBytes: Int?
    /// In-pane find. JSON and raw both highlight hits, step with Enter /
    /// chevrons (`1/N`), and scroll the current hit into view.
    var find: InspectorFind = InspectorFind()
    /// Above this size the collapsible JSON tree gets janky; show raw text
    /// instead (which itself hands large bodies to the lazy `NSTextView`).
    private let jsonRenderLimit = 200_000

    /// One-shot parse result for the current body. Outer nil = the parse for this
    /// body hasn't landed yet; inner nil = parsed and not renderable as a tree
    /// (malformed, scalar, or over the limit) — show raw. Parsing used to happen
    /// inline in `content`, which re-parsed the whole body on every inspector
    /// re-render — ~10×/s under live traffic, milliseconds each at the 200 KB
    /// limit, and re-attempted even after the parse had already failed.
    @State private var parsed: JSONValue??

    /// The decode and the find scan for the current body, done **once** each
    /// rather than once per render — the same trap `parsed` above exists for,
    /// walked back in by find.
    ///
    /// Everything that needs a hit — the `1/N` the action cluster shows, the
    /// wash the raw pane paints, the lines the JSON tree opens — reads this one
    /// value, so they cannot disagree either. Computed per render it cost, on
    /// every keystroke against a 5 MB capture: two UTF-8 decodes of the whole
    /// body (`content` and the count) plus a third in `CodeTextView`, and two
    /// full substring scans; for a JSON body, two whole-tree walks.
    @State private var scan: BodyScan?

    var body: some View {
        VStack(spacing: 0) {
            if let fullBodyBytes { truncationStrip(captured: data?.count ?? 0, wire: fullBodyBytes) }
            content
        }
        .preference(key: InspectorFindReportKey.self, value: findReport)
        // Keyed on the body bytes, not `identity`: the identity is deliberately
        // stable across hydration (the body lands later under the same flow id),
        // so keying on it would leave the tree stuck on the pre-hydration body.
        .task(id: data) {
            guard let data, !data.isEmpty, data.count <= jsonRenderLimit else {
                parsed = .some(nil)
                return
            }
            // Off the main actor — the parse walks a boxed Character array.
            let json = await Self.parse(data)
            guard !Task.isCancelled else { return }
            parsed = .some(json?.isContainer == true ? json : nil)
        }
        .task(id: scanKey) { await rescan() }
    }

    /// `@concurrent`, not `Task.detached` (rationale in `RawTab.build`): the parse
    /// must leave the main actor but must stay cancellable, because `.task(id: data)`
    /// re-fires on every streaming body growth — the case this key exists for — and
    /// a detached parse of the previous, shorter body would run to completion for
    /// nothing while the new one queued behind it on the pool.
    @concurrent private static func parse(_ data: Data) async -> JSONValue? {
        JSONValue.parse(data)
    }

    @ViewBuilder private var content: some View {
        if let data, !data.isEmpty {
            if let json = parsed.flatMap({ $0 }) {
                Scrolled {
                    JSONView(
                        value: json,
                        index: current?.json ?? JSONFindIndex(),
                        findIndex: find.currentIndex
                    )
                }
            } else {
                // Also what shows for the frame or two while the one-shot parse is
                // in flight: immediate and honest, then swaps to the tree.
                rawPane(data)
            }
        } else {
            Scrolled { Text("No body").foregroundStyle(.secondary) }
        }
    }

    /// The raw fallback. `text` is the cached decode whenever the scan for this
    /// body has landed; before it has (the first frame, and only then) it is
    /// decoded inline rather than blinking an empty pane.
    ///
    /// Ranges are handed down only alongside the string they were measured
    /// against — an index taken in one `String` and applied to another is how a
    /// wash lands on the wrong characters.
    private func rawPane(_ data: Data) -> some View {
        let cached = current?.text
        return RawView(
            text: cached ?? String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>",
            identity: identity,
            findActive: find.isActive,
            findRanges: cached == nil ? [] : (current?.ranges ?? []),
            findIndex: find.currentIndex
        )
    }

    /// Honest "you're not seeing everything" strip, same idiom as the flow list's
    /// cap banner: the peer got every byte, but the recorded copy stops at the cap,
    /// so a partial body must never read as a complete one.
    private func truncationStrip(captured: Int, wire: Int) -> some View {
        HStack(spacing: LoomTheme.Space.xs) {
            Image(systemName: "scissors").font(.caption2)
            Text("Captured \(Self.byteCount(captured)) of \(Self.byteCount(wire)) — the rest was forwarded but not recorded")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, LoomTheme.Space.sm)
        .padding(.vertical, LoomTheme.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private static func byteCount(_ bytes: Int) -> String {
        InspectorText.byteCount(bytes)
    }

    // MARK: - The one scan

    /// What a scan is valid for. `identity` alone is not enough (a streaming body
    /// grows under it) and the needle is part of it because a keystroke is what
    /// invalidates the hits — but not the decode, which `rescan` carries over.
    private struct ScanKey: Hashable {
        var identity: AnyHashable
        var bytes: Int
        var isTree: Bool
        var needle: String
    }

    private struct BodyScan {
        var key: ScanKey
        /// The decoded body the `ranges` index into. Nil for a JSON tree, and
        /// for a body that is not UTF-8.
        var text: String?
        var ranges: [Range<String.Index>] = []
        var json = JSONFindIndex()
        var count = 0
    }

    /// Only the parts that cross an isolation boundary. `ScanKey` holds an
    /// `AnyHashable`, which is not `Sendable`, so the key is re-attached here.
    private struct TextScan: Sendable {
        var text: String?
        var ranges: [Range<String.Index>] = []
    }

    private var scanKey: ScanKey {
        ScanKey(
            identity: identity,
            bytes: data?.count ?? 0,
            isTree: parsed.flatMap({ $0 }) != nil,
            needle: find.isActive ? find.trimmed : ""
        )
    }

    /// The scan, when it is the one this render needs. A stale scan is not read:
    /// between a body changing and the task landing, the pane decodes inline.
    private var current: BodyScan? {
        guard let scan, scan.key == scanKey else { return nil }
        return scan
    }

    private var findReport: InspectorFindReport {
        guard find.isActive, let current else { return .empty }
        return InspectorFindReport(matchCount: current.count)
    }

    private func rescan() async {
        let key = scanKey
        if let json = parsed.flatMap({ $0 }) {
            let index = key.needle.isEmpty
                ? JSONFindIndex()
                : await Self.jsonHits(json, needle: key.needle)
            guard !Task.isCancelled else { return }
            scan = BodyScan(key: key, json: index, count: index.count)
            return
        }
        guard let data, !data.isEmpty else {
            scan = BodyScan(key: key)
            return
        }
        // A keystroke changes the needle, not the bytes — carry the decode over
        // rather than paying for it again.
        let reusable = scan.flatMap {
            $0.key.identity == key.identity && $0.key.bytes == key.bytes ? $0.text : nil
        }
        let scanned = await Self.textHits(data, decoded: reusable, needle: key.needle)
        guard !Task.isCancelled else { return }
        scan = BodyScan(key: key, text: scanned.text, ranges: scanned.ranges, count: scanned.ranges.count)
    }

    /// Both halves stay off the main actor for the same reason the parse does:
    /// the body is up to `StreamRelay.captureCap` (5 MB), and the caller is a
    /// view body that also runs while traffic streams.
    @concurrent private static func textHits(
        _ data: Data, decoded: String?, needle: String
    ) async -> TextScan {
        guard let text = decoded ?? String(data: data, encoding: .utf8) else {
            return TextScan(text: nil)
        }
        guard !needle.isEmpty else { return TextScan(text: text) }
        return TextScan(text: text, ranges: InspectorFindMatch.ranges(of: needle, in: text))
    }

    @concurrent private static func jsonHits(
        _ value: JSONValue, needle: String
    ) async -> JSONFindIndex {
        InspectorFindMatch.jsonIndex(value, needle: needle)
    }
}
