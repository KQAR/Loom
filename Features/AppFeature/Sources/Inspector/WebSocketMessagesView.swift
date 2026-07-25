import LoomSharedModels
import SwiftUI

/// WebSocket frame log: one row per message, ↑ client→server / ↓ server→client,
/// with a kind badge and the text (or a byte count for binary/control frames).
struct WebSocketMessagesView: View {
    let messages: [WebSocketMessage]
    /// Frames the capture cap dropped (nil = the log is complete). Shown so a
    /// partial transcript can't read as the whole conversation.
    var droppedMessages: Int?

    var body: some View {
        if messages.isEmpty {
            Text("No frames yet").foregroundStyle(.secondary)
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
                ForEach(messages) { message in
                    HStack(alignment: .top, spacing: LoomTheme.Space.sm) {
                        Image(systemName: message.direction == .clientToServer ? "arrow.up" : "arrow.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(message.direction == .clientToServer ? Color.orange : Color.accentColor)
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
}
