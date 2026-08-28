import AppKit
import LoomSharedModels
import SwiftUI

struct ResponsePane: View {
    let flow: Flow

    enum Tab: Hashable { case messages, raw, headers, cookies, body }
    @State private var tab: Tab = .raw
    @State private var bodyFind = InspectorFind()
    @State private var headersFind = InspectorFind()
    @State private var cookiesFind = InspectorFind()
    @State private var findReport = InspectorFindReport.empty
    /// Whole-tree expand / collapse for the Body tab's JSON view. Owned here rather
    /// than inside `BodyView` because the control that issues it lives in the pane's
    /// floating action cluster, which is a sibling of the body, not a child of it.
    @State private var bodyExpansion = JSONExpansionCommand()
    /// Whether the body is currently a tree — reported up by `BodyView`, because only
    /// it knows whether the parse succeeded and stayed under the render limit.
    @State private var bodyIsOutline = false

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

    private func tabs(_ derived: Derived) -> [InspectorTab<Tab>] {
        let headerCount = flow.response?.headers.count ?? 0
        if flow.isWebSocket {
            // A WebSocket flow's payload is its frames, not a body.
            return [
                InspectorTab("Messages", count: messages.count, tab: .messages),
                InspectorTab("Headers", count: headerCount, tab: .headers),
            ]
        }
        var t: [InspectorTab<Tab>] = [
            InspectorTab("Raw", tab: .raw),
            InspectorTab("Headers", count: headerCount, tab: .headers),
        ]
        if !derived.cookies.isEmpty {
            t.append(InspectorTab("Cookies", count: derived.cookies.count, tab: .cookies))
        }
        t.append(InspectorTab("Body", tab: .body))
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
                .onPreferenceChange(InspectorFindReportKey.self) { findReport = $0 }
                .onPreferenceChange(InspectorBodyOutlineKey.self) { bodyIsOutline = $0 }
                .overlay(alignment: .topTrailing) {
                    paneActions(derived)
                }
        }
        .onAppear { if flow.isWebSocket { tab = .messages } }
        .onChange(of: flow.id) {
            bodyFind = InspectorFind()
            // A new flow is a new body: carrying "expand all" across would open a
            // tree the reader never asked to open, and carrying "collapse all" would
            // hide the thing they just clicked a row to look at.
            bodyExpansion = JSONExpansionCommand()
            headersFind = InspectorFind()
            cookiesFind = InspectorFind()
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
            case .headers: Scrolled {
                HeadersList(headers: response.headers, trailers: response.trailers, find: headersFind)
            }
            case .cookies: Scrolled { CookiesView(cookies: derived.cookies, find: cookiesFind) }
            case .body: BodyView(
                data: response.body,
                identity: "resp-body:\(flow.id)",
                fullBodyBytes: response.fullBodyBytes,
                find: bodyFind,
                expansion: bodyExpansion
            )
            }
        } else if let error = flow.error {
            Scrolled { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(LoomTheme.Palette.error) }
        } else {
            Scrolled { Text("Waiting for response…").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func paneActions(_ derived: Derived) -> some View {
        switch tab {
        case .body:
            if let text = RequestPane.bodyText(flow.response?.body) {
                FloatingPaneActions(
                    copyText: text,
                    copyHelp: "Copy body",
                    find: $bodyFind,
                    report: findReport,
                    // Only when a tree is on screen: a raw or empty body has nothing
                    // to fold, and the command would be a control that does nothing.
                    expansion: bodyIsOutline ? $bodyExpansion : nil
                )
            }
        case .headers:
            if let response = flow.response,
               RequestPane.hasPairs(headers: response.headers, trailers: response.trailers)
            {
                FloatingPaneActions(
                    copyText: HeadersList.copyText(headers: response.headers, trailers: response.trailers),
                    copyHelp: "Copy headers",
                    find: $headersFind,
                    report: findReport
                )
            }
        case .cookies:
            if !derived.cookies.isEmpty {
                FloatingPaneActions(
                    copyText: CookiesView.copyText(derived.cookies),
                    copyHelp: "Copy cookies",
                    find: $cookiesFind,
                    report: findReport
                )
            }
        default:
            EmptyView()
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
        // After the body, which is where they were on the wire — a raw pane that
        // showed them among the headers would misreport when they arrived.
        if let trailers = response.trailers, !trailers.isEmpty {
            lines.append("")
            lines += trailers.map { "\($0.name): \($0.value)" }
        }
        return lines.joined(separator: "\n")
    }
}
