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

    var body: some View {
        VStack(spacing: 0) {
            if let fullBodyBytes { truncationStrip(captured: data?.count ?? 0, wire: fullBodyBytes) }
            content
        }
    }

    @ViewBuilder private var content: some View {
        if let data, !data.isEmpty {
            if data.count <= jsonRenderLimit, let json = JSONValue.parse(data), json.isContainer {
                Scrolled { JSONView(value: json) }
            } else {
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
