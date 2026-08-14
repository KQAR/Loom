import LoomSharedModels
import SwiftUI

/// Everything Loom knows about one **flow** that isn't its headers or its body.
///
/// Flow-scoped, not request-scoped, and the name says so because the placement
/// cannot: it is drawn as the first tab of the *Request* pane, sitting under a
/// heading that describes half of what it reports. Most of these rows are the
/// response's or the connection's — the status code, TTFB and transfer, the
/// response body's size, the whole Connection group (which is entirely about
/// Loom's hop to the origin). Anyone reading `RequestPane` could reasonably
/// conclude the scope is the request and add a row on that basis, or hesitate to
/// add a response-side one; the type name is what stops both.
///
/// Why it lives in the left pane at all is a UI decision recorded in DESIGN.md
/// (§ inspector-parity): one flow-level tab beside the request's own is what
/// every comparable debugger does, and a third pane for two dozen rows is not
/// worth the width.
///
/// Grouped rather than flat, and the grouping is the point: the list grew from
/// nine rows to about twenty-five, and a flat wall of label/value pairs makes the
/// two or three rows that matter for a given question impossible to find. Each
/// group answers one question — *what happened*, *how long*, *how big*, *over
/// what connection*, *from where*, *what did Loom miss* — and a group with
/// nothing to say is absent rather than empty.
///
/// **The groups are separated by space, not by headings.** A heading over three
/// label/value rows adds a third column of words to read and names something the
/// labels beneath it already say (`Server`, `Client TLS`, `Upstream TLS` do not
/// need to be told they are about a connection). The gap carries the grouping and
/// the emphasized labels carry the scan, which is the DESIGN.md rule that type
/// weight and whitespace come before added chrome.
///
/// **A row is present only when Loom measured the thing.** No row says "none" or
/// "0" for something unmeasured: an absent connection group means a response
/// that never touched a socket (a mock, a blocked request), which is a different
/// answer from a connection whose facts happen to be nil, and the surface must
/// not blur them. The capture group is the mirror of that rule — it appears
/// *only* when something is missing, and with no heading left to tint, its own
/// labels carry the warning hue.
struct FlowSummary: View {
    let flow: Flow

    var body: some View {
        // `lg` between groups against `sm` within one: with no headings, the gap
        // is the only thing saying where a group ends, so it has to be clearly
        // more than the row rhythm rather than merely a bit more.
        VStack(alignment: .leading, spacing: LoomTheme.Space.lg) {
            group {
                row("Status", statusText)
                row("Method", flow.request.method, color: LoomTheme.methodColor(flow.request.method))
                // Same hue the table's status dot uses for the same code. Two renderings of
                // one fact used to disagree — a red dot in the list, plain ink here.
                if let code = flow.statusCode {
                    row("Code", "\(code)", color: LoomTheme.statusColor(status: code, isError: false))
                }
                if let host = flow.host { row("Host", host) }
                if let protocols = protocolText { row("Protocol", protocols) }
            }

            group {
                row("Started", flow.startedAt.formatted(date: .abbreviated, time: .standard))
                if let completedAt = flow.completedAt {
                    row("Finished", completedAt.formatted(date: .abbreviated, time: .standard))
                }
                if let ms = flow.durationMS {
                    row("Duration", "\(ms) ms", style: LoomTheme.durationStyle(ms: ms))
                }
                // The split that tells you *where* a slow call is slow: waiting on the
                // server vs transferring the body.
                if let ttfb = flow.ttfbMS { row("TTFB", "\(ttfb) ms") }
                if let receive = flow.receiveMS { row("Transfer", "\(receive) ms") }
            }

            if hasSizes {
                group { sizeRows }
            }

            if let transport = flow.transport, !transport.isEmpty {
                group { connectionRows(transport) }
            }

            if hasOrigin {
                group { originRows }
            }

            // Deliberately last and deliberately conditional: this section exists
            // to say what is *missing* from the capture, and a permanent "nothing
            // missing" row would train the reader to skip past it.
            if hasCaptureGaps {
                group(labelColor: LoomTheme.Palette.warning) { captureRows }
            }

            if let error = flow.error {
                group { row("Error", error, color: LoomTheme.Palette.error) }
            }
        }
        .font(.callout)
    }

    private var statusText: String {
        if flow.error != nil { return "Failed" }
        return flow.response != nil ? "Completed" : "In progress"
    }

    // MARK: - Protocol
    //
    // One row, because the two versions are one answer and reading them apart is
    // what invites the wrong conclusion. Loom re-originates every exchange as
    // HTTP/1.1, so a client on h2 and an upstream hop on HTTP/1.1 is the ordinary
    // case, not a fault — and showing only the upstream one (which is what the
    // table's Protocol column tooltip could offer before this) makes an h2 client
    // read as HTTP/1.1 everywhere in the app.

    private var protocolText: String? {
        let client = flow.request.httpVersion
        let upstream = flow.response?.httpVersion
        switch (client, upstream) {
        case let (client?, upstream?) where client != upstream:
            return "\(client) · \(upstream) upstream"
        case let (client?, _):
            return client
        case let (nil, upstream?):
            return "\(upstream) upstream"
        case (nil, nil):
            return nil
        }
    }

    // MARK: - Size

    private var hasSizes: Bool {
        flow.request.bodyBytes != nil || flow.response?.bodyBytes != nil
    }

    @ViewBuilder private var sizeRows: some View {
        if let requestBytes = flow.request.bodyBytes {
            row("Request body", InspectorText.byteCount(requestBytes))
        }
        if let responseBytes = flow.response?.bodyBytes {
            row("Response body", responseBytes == 0 ? "empty" : responseText(responseBytes))
        }
    }

    /// The decoded size, plus what actually crossed the wire when the origin
    /// compressed it. Both numbers or neither: quoting only the decoded one makes
    /// a 40 KB JSON response look like 40 KB of bandwidth when it was 4.
    private func responseText(_ decoded: Int) -> String {
        let text = InspectorText.byteCount(decoded)
        guard let encoded = flow.transport?.responseEncodedBodyBytes,
              let encoding = flow.transport?.responseContentEncoding,
              encoded > 0, encoded < decoded else { return text }
        let ratio = Double(decoded) / Double(encoded)
        return "\(text) · \(InspectorText.byteCount(encoded)) \(encoding) on the wire (\(String(format: "%.1f", ratio))×)"
    }

    // MARK: - Connection

    @ViewBuilder private func connectionRows(_ transport: FlowTransport) -> some View {
        Group {
            if let address = transport.remoteAddress { row("Server", address) }
            if let reused = transport.connectionReused {
                // Worth a row even when false: a fresh connection is the
                // explanation for a TTFB that looks anomalous next to its
                // neighbours, and "no row" would leave that unanswered.
                row("Connection", reused ? "reused" : "new (connect + handshake)")
            }
            if let setup = transport.setup, let text = setupText(setup) { row("Setup", text) }
            if let send = transport.requestSendMS, send > 0 { row("Request sent in", "\(send) ms") }
            if let version = transport.clientTLSVersion { row("Client TLS", version) }
            // **Loud, and in the warning colour**, because the row above it
            // (`request.httpVersion`, "HTTP/1.1") is true about what happened and
            // false about what the app would have done — and this pane is what
            // someone reads when comparing a capture with production. A quiet row
            // saying "downgraded" would be read as a property of the client.
            if transport.clientProtocolDowngraded == true {
                row(
                    "Client protocol",
                    "HTTP/1.1 — forced by Loom (its HTTP/2 decoder refused this host's header block)",
                    color: LoomTheme.Palette.warning
                )
            }
            if let tls = transport.upstreamTLS { upstreamTLSRows(tls) }
        }
    }

    /// The connection's setup cost, phase by phase.
    ///
    /// One row rather than three: they are one answer to one question ("what did
    /// opening this cost, and which part of it"), and three rows would push the
    /// TLS details that follow off the first screen for a number that is usually
    /// a footnote. The total leads because it is what a reader compares against
    /// the duration above; the breakdown is what they read next if it is large.
    private func setupText(_ setup: ConnectionSetup) -> String? {
        var parts: [String] = []
        if let dns = setup.dnsMS { parts.append("DNS \(dns) ms") }
        if let tcp = setup.tcpMS { parts.append("connect \(tcp) ms") }
        if let handshake = setup.tlsHandshakeMS { parts.append("TLS \(handshake) ms") }
        guard !parts.isEmpty else { return nil }
        guard let total = setup.totalMS, parts.count > 1 else { return parts.joined(separator: " · ") }
        return "\(total) ms — " + parts.joined(separator: " · ")
    }

    @ViewBuilder private func upstreamTLSRows(_ tls: UpstreamTLSInfo) -> some View {
        Group {
            if let version = tls.version {
                row("Upstream TLS", tls.serverName.map { "\(version) · SNI \($0)" } ?? version)
            }
            if let identity = tls.clientCertificate { row("Sent identity", identity) }
            if let issuer = tls.certificate?.issuer { row("Issuer", issuer) }
            if let certificate = tls.certificate, let notAfter = certificate.notAfter {
                row(
                    "Expires",
                    notAfter.formatted(date: .abbreviated, time: .shortened),
                    // Judged against the moment the exchange ran, not against now:
                    // a flow read back a week later must not re-answer a question
                    // about a connection that already happened.
                    color: certificate.isValid(at: flow.startedAt) ? .primary : LoomTheme.Palette.error
                )
            }
        }
    }

    // MARK: - Origin

    private var hasOrigin: Bool {
        flow.sourceApp != nil || flow.sourceDevice != nil || flow.replayedFrom != nil
            || flow.importedFrom != nil || !(flow.appliedRules ?? []).isEmpty
    }

    @ViewBuilder private var originRows: some View {
        if let app = flow.sourceApp { row("App", appText(app)) }
        if let device = flow.sourceDevice { row("Device", deviceText(device)) }
        if let replayedFrom = flow.replayedFrom {
            // The id, not just the word: it is what `diff_flows` and
            // `get_flow_detail` take, so it has to be selectable.
            row("Replayed from", replayedFrom.uuidString)
        }
        if let importedFrom = flow.importedFrom { row("Imported from", importedFrom) }
        if let rules = flow.appliedRules, !rules.isEmpty {
            row("Rules", rules.map(\.name).joined(separator: ", "), color: LoomTheme.Palette.accent)
        }
    }

    /// The pid when there is one, and otherwise a plain statement of where the
    /// name came from. A `User-Agent` attribution is a claim by the client, not a
    /// measurement, and a row that read just `YqdCredmex` would invite it to be
    /// taken for the same kind of answer as `Safari (pid 431)`.
    private func appText(_ app: SourceApp) -> String {
        if let pid = app.pid { return "\(app.name) (pid \(pid))" }
        return "\(app.name) (from User-Agent)"
    }

    private func deviceText(_ device: SourceDevice) -> String {
        let descriptors = [device.platform, device.client].compactMap { $0 }
        guard !descriptors.isEmpty else { return device.ip }
        return "\(device.ip) · \(descriptors.joined(separator: " "))"
    }

    // MARK: - Capture
    //
    // The four ways this flow is less than what crossed the wire. Each was already
    // recorded on the model and reachable from `get_flow_detail`, and none of them
    // reached the human's summary — so a truncated exchange read here exactly like
    // a complete one, which is the failure `fullBodyBytes` exists to prevent one
    // layer down.

    private var hasCaptureGaps: Bool {
        flow.request.isBodyTruncated || flow.response?.isBodyTruncated == true
            || flow.webSocketDroppedMessages != nil || flow.webSocketCaptureError != nil
            || flow.bodiesEvicted == true
    }

    @ViewBuilder private var captureRows: some View {
        if let wire = flow.request.fullBodyBytes {
            row("Request body", "\(InspectorText.byteCount(flow.request.body?.count ?? 0)) of \(InspectorText.byteCount(wire)) recorded")
        }
        if let wire = flow.response?.fullBodyBytes {
            row("Response body", "\(InspectorText.byteCount(flow.response?.body?.count ?? 0)) of \(InspectorText.byteCount(wire)) recorded")
        }
        if flow.bodiesEvicted == true {
            // Not the same as a capture cap, and the next move differs: this one
            // cannot be fixed by re-reading — the bytes are gone.
            row("Bodies", "captured, then discarded to stay inside the memory budget")
        }
        if let dropped = flow.webSocketDroppedMessages { row("Frames", "\(dropped) not recorded") }
        if let frameError = flow.webSocketCaptureError { row("Frame log", "stopped: \(frameError)") }
    }

    // MARK: - Rows

    /// One group of rows. No heading — the enclosing stack's larger spacing is
    /// what separates it from the next (see the type's note).
    ///
    /// `labelColor` exists for the capture group alone: it is the one group whose
    /// mere presence is the message, and with the tinted heading gone its labels
    /// are what has to carry that.
    @ViewBuilder private func group(
        labelColor: Color? = nil, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
            content()
        }
        .environment(\.summaryLabelColor, labelColor)
    }

    /// `color` covers the common case; `style` exists for the one row whose ink is a
    /// *hierarchical* style rather than a hue (Duration — see `LoomTheme.durationStyle`).
    private func row(_ label: String, _ value: String, color: Color = .primary) -> some View {
        row(label, value, style: AnyShapeStyle(color))
    }

    private func row(_ label: String, _ value: String, style: AnyShapeStyle) -> some View {
        SummaryRow(label: label, value: value, style: style)
    }
}

/// A label/value pair.
///
/// Its own view rather than a method so it can read `summaryLabelColor` — a
/// `@ViewBuilder` method on the table would evaluate in the table's environment,
/// which is the one place the group's tint has not been applied yet.
private struct SummaryRow: View {
    let label: String
    let value: String
    let style: AnyShapeStyle
    @Environment(\.summaryLabelColor) private var labelColor

    var body: some View {
        HStack(alignment: .top, spacing: LoomTheme.Space.md) {
            Text(label)
                // Emphasis, not a second ink: the labels are the column a reader
                // scans down to find the one row they came for, and with the
                // headings gone that scan is all the structure there is. Weight
                // does it without spending a colour, which in this app means a
                // status (DESIGN.md § Colors).
                .fontWeight(.semibold)
                .foregroundStyle(labelColor ?? .secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .foregroundStyle(style)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

private extension EnvironmentValues {
    /// Set by a group that needs its labels to carry a warning; nil everywhere
    /// else, which leaves the row's own secondary ink alone.
    @Entry var summaryLabelColor: Color?
}
