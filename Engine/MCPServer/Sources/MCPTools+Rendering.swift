import Foundation
import LoomSharedModels

/// Turning domain values into the JSON an agent reads: flow summaries and
/// details, header maps, and the body window (bodies are truncated to keep a
/// response readable — and a truncated capture always says so, never silently).
extension MCPToolExecutor {
    /// `ISO8601DateFormatter` is expensive to allocate; render every timestamp
    /// through one shared instance.
    ///
    /// `nonisolated(unsafe)`: Foundation's formatters are documented thread-safe
    /// for formatting as long as nothing mutates them after configuration, which
    /// nothing here does — both instances are configured in their initializer and
    /// only ever asked to `string(from:)` / `date(from:)`. The class simply isn't
    /// marked `Sendable`. Do not add a `formatOptions` write anywhere else.
    nonisolated(unsafe) static let iso8601 = ISO8601DateFormatter()

    /// Parse-only companion: agents (and JS clients) routinely send fractional
    /// seconds, which the default formatter rejects.
    nonisolated(unsafe) static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Rendering

    static func flowSummary(_ flow: Flow) -> [String: Any] {
        MCPRender.dict(FlowSummaryRender(flow))
    }

    /// One flow rendered for `get_flow_detail`. Bodies go through `bodyField`, so
    /// a multi-megabyte response is bounded (with a `nextOffset` to page from) and
    /// a binary payload is labelled instead of silently becoming `""` — an agent
    /// must be able to tell "no body" from "2 MB of PNG".
    static func flowDetail(
        _ flow: Flow,
        offset: Int = 0,
        maxBytes: Int = defaultBodyBytes,
        webSocketLimit: Int = defaultWebSocketMessages
    ) -> [String: Any] {
        var webSocket: RenderedWebSocket?
        if let messages = flow.webSocketMessages {
            // A chatty socket records up to 10k frames; returning them all would
            // flood the agent's context, so hand back the most recent slice and say
            // so. Each frame's text is capped the same way a body is.
            let shown = messages.suffix(webSocketLimit)
            webSocket = RenderedWebSocket(
                messageCount: messages.count,
                messages: shown.map { message in
                    RenderedWebSocketMessage(
                        direction: message.direction.rawValue,
                        kind: message.kind.rawValue,
                        isFinal: message.isFinal,
                        text: message.textPayload != nil
                            ? bodyField(message.payload, maxBytes: maxBytes) : nil,
                        bytes: message.textPayload == nil ? message.payload.count : nil
                    )
                },
                messagesTruncated: shown.count < messages.count ? true : nil,
                messagesShown: shown.count < messages.count ? shown.count : nil,
                // Frames the *capture* cap dropped — never recorded, so no paging can
                // recover them. Distinct from the render cap above.
                framesNotRecorded: flow.webSocketDroppedMessages,
                // Parsing gave up mid-connection: the frame log ends here even though
                // the socket didn't. Distinct from both caps above — nothing after this
                // point was ever seen as a frame, so there is no count to give.
                captureStopped: flow.webSocketCaptureError
            )
        }
        let detail = FlowDetailRender(
            request: RenderedRequest(
                flow.request,
                body: bodyField(flow.request.body, offset: offset, maxBytes: maxBytes)
            ),
            response: flow.response.map { response in
                RenderedResponse(
                    response,
                    body: bodyField(response.body, offset: offset, maxBytes: maxBytes)
                )
            },
            graphQL: GraphQLParser.parse(flow.request).map(RenderedGraphQL.init),
            webSocket: webSocket
        )
        // Merged over the summary rather than restating it: the detail owns only the
        // keys it adds, and `webSocket` deliberately *replaces* the summary's bare
        // `true` with the frame log.
        return flowSummary(flow).merging(MCPRender.dict(detail)) { _, detail in detail }
    }

    /// Default body budget per side for one tool call. Big enough for a normal API
    /// payload, small enough that one flow can't blow up an agent's context; the
    /// caller can raise it (or page) with `max_bytes` / `body_offset`.
    static let defaultBodyBytes = 16_384

    /// Default number of WebSocket frames returned by `get_flow_detail`.
    static let defaultWebSocketMessages = 100

    /// Render a body for an agent: UTF-8 text when it decodes, `{binary, bytes}`
    /// when it doesn't (never a silent `""` — "no body" and "2 MB of PNG" must be
    /// distinguishable), always bounded by `maxBytes`. `offset` pages into a large
    /// body; the window is a *byte* range, so a code point straddling either edge
    /// is trimmed rather than rendered as replacement characters.
    static func bodyField(_ data: Data?, offset: Int = 0, maxBytes: Int = defaultBodyBytes) -> RenderedBody {
        guard let data, !data.isEmpty else { return .text("") }
        let total = data.count
        let start = min(max(0, offset), total)
        let end = min(total, start + max(0, maxBytes))
        let window = Data(data[data.startIndex.advanced(by: start) ..< data.startIndex.advanced(by: end)])
        // Only forgive bytes at an edge we actually cut. An un-cut window that
        // doesn't decode is genuinely binary — trimming it anyway would let a PNG
        // header render as text.
        guard let text = utf8Text(window, trimLeading: start > 0, trimTrailing: end < total) else {
            return .binary(bytes: total)
        }
        // Whole body, from the start: return it plainly (the common small-body case).
        if start == 0, end == total { return .text(text) }
        return .window(preview: text, bytes: total, offset: start, nextOffset: end < total ? end : nil)
    }

    /// Decode a byte window as UTF-8, dropping a leading continuation fragment and
    /// a trailing incomplete code point (both artifacts of slicing on byte
    /// boundaries). Nil when the bytes aren't text at all — i.e. a binary body.
    static func utf8Text(_ window: Data, trimLeading: Bool, trimTrailing: Bool) -> String? {
        var bytes = [UInt8](window)
        // A code point that began before `offset` leaves up to 3 continuation bytes.
        if trimLeading {
            var lead = 0
            while lead < bytes.count, lead < 3, bytes[lead] & 0xC0 == 0x80 { lead += 1 }
            if lead > 0 { bytes.removeFirst(lead) }
        }
        // A code point cut by the cap leaves up to 3 bytes at the tail.
        if trimTrailing {
            for _ in 0 ... 3 {
                if let text = String(bytes: bytes, encoding: .utf8) { return text }
                if bytes.isEmpty { return nil }
                bytes.removeLast()
            }
            return nil
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    static func headerDict(_ headers: [HeaderPair]) -> [String: String] {
        Dictionary(headers.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    /// Keep `list_rules` light: long bodies are cut to a preview + total length so
    /// a rule list with big JSON mocks doesn't flood the agent's context.
    static func addBody(_ text: String?, to out: inout [String: Any], truncate: Bool) {
        guard let text else { return }
        let limit = 200
        if truncate, text.count > limit {
            out["body"] = String(text.prefix(limit))
            out["bodyLength"] = text.count
            out["bodyTruncated"] = true
        } else {
            out["body"] = text
        }
    }
}
