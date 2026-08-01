import AppKit
import SwiftUI

struct BodyView: View {
    let data: Data?
    let identity: AnyHashable
    /// Total bytes that crossed the wire when `data` is only the captured prefix
    /// (nil = complete). Drives the "this is partial" strip.
    var fullBodyBytes: Int?
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
        // Keyed on the body bytes, not `identity`: the identity is deliberately
        // stable across hydration (the body lands later under the same flow id),
        // so keying on it would leave the tree stuck on the pre-hydration body.
        .task(id: data) {
            guard let data, !data.isEmpty, data.count <= jsonRenderLimit else {
                parsed = .some(nil)
                return
            }
            // Off the main actor — the parse walks a boxed Character array.
            let json = await Task.detached { JSONValue.parse(data) }.value
            guard !Task.isCancelled else { return }
            parsed = .some(json?.isContainer == true ? json : nil)
        }
    }

    @ViewBuilder private var content: some View {
        if let data, !data.isEmpty {
            if let json = parsed.flatMap({ $0 }) {
                Scrolled { JSONView(value: json) }
            } else {
                // Also what shows for the frame or two while the one-shot parse is
                // in flight: immediate and honest, then swaps to the tree.
                RawView(text: String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>", identity: identity)
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

    /// Hoisted formatter — a per-render `ByteCountFormatter` would allocate on
    /// every body open.
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter
    }()

    private static func byteCount(_ bytes: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(bytes))
    }
}
