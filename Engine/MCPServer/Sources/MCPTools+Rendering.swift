import Foundation
import LoomSharedModels

/// Turning domain values into the JSON an agent reads: flow summaries and
/// details, header maps, and the body window (bodies are truncated to keep a
/// response readable — and a truncated capture always says so, never silently).
extension MCPToolExecutor {
    /// `ISO8601DateFormatter` is expensive to allocate; render every timestamp
    /// through one shared instance.
    static let iso8601 = ISO8601DateFormatter()

    /// Parse-only companion: agents (and JS clients) routinely send fractional
    /// seconds, which the default formatter rejects.
    static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Rendering

    static func flowSummary(_ flow: Flow) -> [String: Any] {
        var out: [String: Any] = [
            "id": flow.id.uuidString,
            "method": flow.request.method,
            "url": flow.request.url,
            // When it happened — without this an agent can't tell a flow from three
            // hours ago from the one it just triggered, nor order across calls.
            "startedAt": iso8601.string(from: flow.startedAt),
        ]
        if let status = flow.statusCode { out["status"] = status }
        if let ms = flow.durationMS { out["durationMS"] = ms }
        // Split the duration so "why is this slow" is answerable: ttfb is the
        // server's share, receive is the payload's.
        if let ms = flow.ttfbMS { out["ttfbMS"] = ms }
        if let ms = flow.receiveMS { out["receiveMS"] = ms }
        if let error = flow.error { out["error"] = error }
        if let from = flow.replayedFrom { out["replayedFrom"] = from.uuidString }
        // Loaded from a file, not observed here — the one thing that must never be
        // implicit about an imported flow.
        if let importedFrom = flow.importedFrom { out["importedFrom"] = importedFrom }
        if let applied = flow.appliedRules { out["appliedRules"] = applied.map(\.name) }
        if let messages = flow.webSocketMessages {
            out["webSocket"] = true
            out["wsMessageCount"] = messages.count
        }
        // Flag a partially-captured exchange in the *summary* too, so an agent
        // knows a body is a prefix before it fetches (or diffs) the detail.
        if flow.request.isBodyTruncated || flow.response?.isBodyTruncated == true
            || flow.webSocketDroppedMessages != nil {
            out["captureTruncated"] = true
        }
        if let app = flow.sourceApp {
            var appOut: [String: Any] = ["name": app.name, "pid": Int(app.pid)]
            if let bundleID = app.bundleID { appOut["bundleID"] = bundleID }
            out["sourceApp"] = appOut
        }
        if let device = flow.sourceDevice {
            var deviceOut: [String: Any] = ["ip": device.ip, "kind": device.kind.rawValue]
            if let platform = device.platform { deviceOut["platform"] = platform }
            if let client = device.client { deviceOut["client"] = client }
            out["sourceDevice"] = deviceOut
        }
        return out
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
        var out = flowSummary(flow)
        var requestOut: [String: Any] = [
            "method": flow.request.method,
            "url": flow.request.url,
            "headers": flow.request.headers.map { ["name": $0.name, "value": $0.value] },
            "body": bodyField(flow.request.body, offset: offset, maxBytes: maxBytes),
        ]
        // Capture truncation is a different fact from render truncation above: the
        // recorded copy itself is a prefix, so no `body_offset` can reach the rest.
        // Say so explicitly, with the real wire size.
        if let wireBytes = flow.request.fullBodyBytes {
            requestOut["bodyCaptureTruncated"] = true
            requestOut["bodyBytesOnWire"] = wireBytes
        }
        out["request"] = requestOut
        if let response = flow.response {
            var responseOut: [String: Any] = [
                "status": response.statusCode,
                "headers": response.headers.map { ["name": $0.name, "value": $0.value] },
                "body": bodyField(response.body, offset: offset, maxBytes: maxBytes),
            ]
            if let version = response.httpVersion { responseOut["httpVersion"] = version }
            if let wireBytes = response.fullBodyBytes {
                responseOut["bodyCaptureTruncated"] = true
                responseOut["bodyBytesOnWire"] = wireBytes
            }
            out["response"] = responseOut
        }
        if let graphQL = GraphQLParser.parse(flow.request) {
            var gql: [String: Any] = ["kind": graphQL.kind.rawValue, "query": graphQL.query]
            if let name = graphQL.operationName { gql["operationName"] = name }
            if let variables = graphQL.variablesJSON { gql["variables"] = variables }
            out["graphQL"] = gql
        }
        if let messages = flow.webSocketMessages {
            // A chatty socket records up to 10k frames; returning them all would
            // flood the agent's context, so hand back the most recent slice and say
            // so. Each frame's text is capped the same way a body is.
            let shown = messages.suffix(webSocketLimit)
            var ws: [String: Any] = [
                "messageCount": messages.count,
                "messages": shown.map { message in
                    var msg: [String: Any] = [
                        "direction": message.direction.rawValue,
                        "kind": message.kind.rawValue,
                        "isFinal": message.isFinal,
                    ]
                    if message.textPayload != nil {
                        msg["text"] = bodyField(message.payload, maxBytes: maxBytes)
                    } else {
                        msg["bytes"] = message.payload.count
                    }
                    return msg
                },
            ]
            if shown.count < messages.count {
                ws["messagesTruncated"] = true
                ws["messagesShown"] = shown.count
            }
            // Frames the *capture* cap dropped — never recorded, so no paging can
            // recover them. Distinct from the render cap above.
            if let dropped = flow.webSocketDroppedMessages {
                ws["framesNotRecorded"] = dropped
            }
            out["webSocket"] = ws
        }
        return out
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
    static func bodyField(_ data: Data?, offset: Int = 0, maxBytes: Int = defaultBodyBytes) -> Any {
        guard let data, !data.isEmpty else { return "" }
        let total = data.count
        let start = min(max(0, offset), total)
        let end = min(total, start + max(0, maxBytes))
        let window = Data(data[data.startIndex.advanced(by: start) ..< data.startIndex.advanced(by: end)])
        // Only forgive bytes at an edge we actually cut. An un-cut window that
        // doesn't decode is genuinely binary — trimming it anyway would let a PNG
        // header render as text.
        guard let text = utf8Text(window, trimLeading: start > 0, trimTrailing: end < total) else {
            return ["binary": true, "bytes": total]
        }
        // Whole body, from the start: return it plainly (the common small-body case).
        if start == 0, end == total { return text }
        var out: [String: Any] = ["truncated": true, "preview": text, "bytes": total, "offset": start]
        if end < total { out["nextOffset"] = end }
        return out
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
