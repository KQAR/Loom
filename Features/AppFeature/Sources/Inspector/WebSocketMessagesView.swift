import LoomSharedModels
import SwiftUI

/// WebSocket frame log: one row per message, ↑ client→server / ↓ server→client,
/// with a kind badge and the text (or a byte count for binary/control frames).
struct WebSocketMessagesView: View {
    let messages: [WebSocketMessage]
    /// Frames the capture cap dropped (nil = the log is complete). Shown so a
    /// partial transcript can't read as the whole conversation.
    var droppedMessages: Int?
    /// Set when frame parsing gave up on this connection — the log stops here even
    /// though the socket may still be live. Shown even with no frames at all, which
    /// is the case a bare "No frames yet" would misread as a quiet socket.
    var captureError: String?

    var body: some View {
        if messages.isEmpty {
            VStack(alignment: .leading, spacing: LoomTheme.Space.xs) {
                if let captureError { captureStoppedLabel(captureError) }
                Text("No frames yet").foregroundStyle(.secondary)
            }
        } else {
            // Lazy: a chatty socket records up to 10k frames, and an eager `VStack`
            // would lay out every one of them on open (AGENTS.md: never render an
            // unbounded collection eagerly).
            LazyVStack(alignment: .leading, spacing: LoomTheme.Space.xs) {
                if let droppedMessages {
                    Label(
                        "Frame log capped — \(droppedMessages) later frames were relayed but not recorded",
                        systemImage: "scissors"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let captureError { captureStoppedLabel(captureError) }
                ForEach(messages) { message in
                    HStack(alignment: .top, spacing: LoomTheme.Space.sm) {
                        Image(systemName: message.direction == .clientToServer ? "arrow.up" : "arrow.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(message.direction == .clientToServer ? LoomTheme.Palette.warning : LoomTheme.Palette.accent)
                            .frame(width: 14)
                        CapsuleBadge(text: message.kind.rawValue, hPadding: 5, vPadding: 1)
                        if let text = message.textPayload {
                            Text(text)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("\(message.payload.count) bytes")
                                .font(.callout.monospaced())
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private func captureStoppedLabel(_ reason: String) -> some View {
        Label(
            "Frame capture stopped — \(reason). Bytes are still being relayed.",
            systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(LoomTheme.Palette.warning)
    }
}
