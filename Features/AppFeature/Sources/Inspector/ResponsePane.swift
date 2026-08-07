import AppKit
import LoomSharedModels
import SwiftUI

struct ResponsePane: View {
    let flow: Flow
    let onClose: () -> Void

    enum Tab: Hashable { case messages, raw, headers, cookies, body }
    @State private var tab: Tab = .raw

    /// Same reason as `RequestPane.Derived`: `tabs` needs the cookies (to decide
    /// whether the tab exists) and `content` needs them (to render it), so as a
    /// computed property each render re-split every `Set-Cookie` header two or
    /// three times over. That matters on the streaming path, where an open
    /// inspector re-renders every ~100 ms batch while the request is in flight.
    private struct Derived {
        var cookies: [CookieItem]
    }

    private static func derive(_ flow: Flow) -> Derived {
        Derived(cookies: CookieParsing.responseCookies(flow.response?.headers ?? []))
    }

    private var messages: [WebSocketMessage] { flow.webSocketMessages ?? [] }

    private func tabs(_ derived: Derived) -> [(String, Tab)] {
        if flow.isWebSocket {
            // A WebSocket flow's payload is its frames, not a body.
            return [("Messages(\(messages.count))", .messages), ("Headers(\(flow.response?.headers.count ?? 0))", .headers)]
        }
        var t: [(String, Tab)] = [
            ("Raw", .raw),
            ("Headers(\(flow.response?.headers.count ?? 0))", .headers),
        ]
        if !derived.cookies.isEmpty { t.append(("Cookies(\(derived.cookies.count))", .cookies)) }
        t.append(("Body", .body))
        return t
    }

    var body: some View {
        let derived = Self.derive(flow)
        return VStack(spacing: 0) {
            HStack(spacing: LoomTheme.Space.sm) {
                InspectorTabStrip(tabs: tabs(derived), selection: $tab)
                Spacer(minLength: LoomTheme.Space.xs)
                if let code = flow.statusCode {
                    StatusBadge(code: code)
                } else if flow.error != nil {
                    StatusBadge(code: nil)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("Close detail")
                .help("Close detail")
            }
            .padding(.horizontal, LoomTheme.Space.md)
            .frame(height: 34)
            Divider()

            // Rule audit trail: on the Raw tab, say plainly that this response
            // was shaped by rules (mocked/rewritten/blocked/delayed) and by which.
            if tab == .raw, let applied = flow.appliedRules, !applied.isEmpty {
                HStack(spacing: LoomTheme.Space.xs) {
                    Image(systemName: "wand.and.stars")
                        .font(.caption)
                    Text("Modified by \(applied.count == 1 ? "rule" : "rules"): \(applied.map(\.name).joined(separator: ", "))")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(LoomTheme.Palette.accent)
                .padding(.horizontal, LoomTheme.Space.md)
                .padding(.vertical, LoomTheme.Space.xs)
                .background(LoomTheme.Palette.accent.opacity(LoomTheme.attentionOpacity))
                Divider()
            }

            content(derived)
                .overlay(alignment: .topTrailing) {
                    if tab == .body, let text = RequestPane.bodyText(flow.response?.body) {
                        FloatingCopyButton(text: text)
                    }
                }
        }
        .onAppear { if flow.isWebSocket { tab = .messages } }
        .onChange(of: flow.id) {
            if flow.isWebSocket { tab = .messages }
            else if tab == .messages { tab = .raw }
            else if tab == .cookies, derived.cookies.isEmpty { tab = .raw }
        }
    }

    /// See `RequestPane.content`: each tab scrolls itself; Raw/Body route large
    /// payloads to the viewport-lazy `NSTextView`.
    @ViewBuilder private func content(_ derived: Derived) -> some View {
        if tab == .messages {
            Scrolled { WebSocketMessagesView(
                messages: messages,
                droppedMessages: flow.webSocketDroppedMessages,
                captureError: flow.webSocketCaptureError
            ) }
        } else if let response = flow.response {
            switch tab {
            case .messages: EmptyView()
            case .raw: RawTab(flow: flow, pane: "resp", makeText: Self.rawText)
            case .headers: Scrolled { HeadersList(headers: response.headers) }
            case .cookies: Scrolled { CookiesView(cookies: derived.cookies) }
            case .body: BodyView(data: response.body, identity: "resp-body:\(flow.id)", fullBodyBytes: response.fullBodyBytes)
            }
        } else if let error = flow.error {
            Scrolled { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(LoomTheme.Palette.error) }
        } else {
            Scrolled { Text("Waiting for response…").foregroundStyle(.secondary) }
        }
    }

    nonisolated static func rawText(_ flow: Flow) -> String {
        guard let response = flow.response else { return "" }
        var lines = ["HTTP \(response.statusCode)"]
        lines += response.headers.map { "\($0.name): \($0.value)" }
        lines.append("")
        if let body = response.body, let string = String(data: body, encoding: .utf8) {
            lines.append(string)
        }
        return lines.joined(separator: "\n")
    }
}
