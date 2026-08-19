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
                        findNeedle: find.isActive ? find.trimmed : "",
                        findIndex: find.currentIndex
                    )
                }
            } else {
                // Also what shows for the frame or two while the one-shot parse is
                // in flight: immediate and honest, then swaps to the tree.
                RawView(
                    text: String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>",
                    identity: identity,
                    findNeedle: find.isActive ? find.trimmed : "",
                    findIndex: find.currentIndex
                )
            }
        } else {
            Scrolled { Text("No body").foregroundStyle(.secondary) }
        }
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

    private var findReport: InspectorFindReport {
        guard find.isActive else { return .empty }
        if let json = parsed.flatMap({ $0 }) {
            return InspectorFindReport(
                matchCount: InspectorFindMatch.jsonMatchCount(json, needle: find.trimmed)
            )
        }
        guard let data, let text = String(data: data, encoding: .utf8) else { return .empty }
        return InspectorFindReport(
            matchCount: InspectorFindMatch.ranges(of: find.trimmed, in: text).count
        )
    }
}
