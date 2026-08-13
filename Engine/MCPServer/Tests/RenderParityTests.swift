import Foundation
import LoomSharedModels
import Testing
@testable import MCPServer

/// Keeps every agent-facing render from drifting away from the model it renders.
///
/// ## The failure this exists to catch
///
/// A field added to `Flow` compiles everywhere. The model is `Codable`, so its own
/// serialization grows for free; the render does not, and nothing anywhere says
/// so — the agent simply never sees the new field, and the next person to look
/// concludes Loom doesn't record it. That already happened once to rules
/// (`RuleCodecParityTests`, and the `carried*` fields in `RuleDraft` are its
/// scar), and the same hole was open on every other model.
///
/// ## What it checks
///
/// A census, not an equality: for each model/render pair, every **stored property
/// of the model** must either appear as a stored property of the render, or be
/// listed in `accountedFor` with the reason. Renders are allowed extra fields —
/// shaping is their job (`ttfbMS` is computed, `captureTruncated` folds four model
/// fields into one answer) — so the check is one-directional, and the reasons are
/// where the shaping is written down.
///
/// Stale entries fail too: an `accountedFor` key that is no longer a model field
/// means the note outlived the thing it explained.
///
/// Stored properties come from `Mirror` rather than from encoding a value,
/// because a field is missing from an encoding exactly when it is nil — which is
/// the case a census must not be blind to — and because two of the models here
/// (`FlowStats.Bucket`, `GraphQLOperation`) aren't `Codable` at all.
@Suite struct RenderParityTests {
    // MARK: - The census

    /// One model, one render, and every model field the render doesn't carry
    /// verbatim — each with why.
    private struct Census {
        let name: String
        let model: Set<String>
        let render: Set<String>
        /// model field → why the render doesn't have a field of that name.
        let accountedFor: [String: String]

        init(
            _ name: String,
            model: Any,
            render: Any,
            accountedFor: [String: String] = [:]
        ) {
            self.name = name
            self.model = Self.fields(of: model)
            self.render = Self.fields(of: render)
            self.accountedFor = accountedFor
        }

        private static func fields(of value: Any) -> Set<String> {
            Set(Mirror(reflecting: value).children.compactMap(\.label))
        }
    }

    private func check(_ census: Census) {
        let unexplained = census.model.subtracting(census.render)
            .subtracting(census.accountedFor.keys)
        #expect(
            unexplained.isEmpty,
            """
            \(census.name): model field(s) \(unexplained.sorted()) reach no render field \
            and are not listed as deliberately folded or renamed. An agent cannot see them. \
            Either add them to the render or record the reason in this test's `accountedFor`.
            """
        )
        let stale = Set(census.accountedFor.keys).subtracting(census.model)
        #expect(
            stale.isEmpty,
            "\(census.name): `accountedFor` explains \(stale.sorted()), which the model no longer has."
        )
    }

    // MARK: - Fixtures
    //
    // Values, not maximal values: `Mirror` reports a stored property whether or not
    // it holds anything, which is the whole reason the census reads properties
    // rather than an encoding.

    private var flow: Flow {
        Flow(
            request: CapturedRequest(method: "GET", url: "https://api.example.test/v1", headers: []),
            startedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private var pending: PendingBreakpoint {
        PendingBreakpoint(
            breakpointID: UUID(),
            phase: .request,
            method: "GET",
            url: "https://api.example.test/v1",
            requestHeaders: []
        )
    }

    private var bucket: FlowStats.Bucket {
        FlowStats.compute(flows: [flow], grouping: .host).total
    }

    // MARK: - Flows

    @Test func flowSummaryAndDetail_carryEveryModelField() {
        let flow = flow
        // Summary and detail are one render split in two — the detail merges its
        // keys over the summary's — so the census reads them together.
        check(Census(
            "Flow → get_recent_flows / get_flow_detail",
            model: flow,
            render: FlowSummaryRender(flow),
            accountedFor: [
                "request": "get_flow_detail renders it as `request` (FlowDetailRender); the summary lifts method/url out of it",
                "outcome": "folded: the sum type becomes `status` + `error` in the summary and `response` in the detail",
                "firstByteAt": "folded into the derived `ttfbMS` / `receiveMS`, which is what it exists to make answerable",
                "webSocketMessages": "folded into `webSocket` — a bare `true` + `wsMessageCount` in the summary, the frame log in the detail",
                "webSocketDroppedMessages": "folded into `captureTruncated` (summary) and `webSocket.framesNotRecorded` (detail)",
                "webSocketCaptureError": "folded into `captureTruncated` (summary) and `webSocket.captureStopped` (detail)",
                "transport": "get_flow_detail renders it as `transport` (FlowDetailRender); kept off the summary, which is a list read that no connection fact helps you filter",
            ]
        ))
    }

    @Test func transport_carriesEveryModelField() {
        // Non-empty values: the render's initializer returns nil for an empty
        // one, and `Mirror` needs an instance to report properties from.
        let certificate = PeerCertificateInfo(subject: "CN=a.test")
        let tls = UpstreamTLSInfo(version: "TLSv1.3", certificate: certificate)
        let transport = FlowTransport(remoteAddress: "127.0.0.1:443", upstreamTLS: tls)

        check(Census(
            "FlowTransport → get_flow_detail.transport",
            model: transport,
            render: RenderedTransport(transport)!
        ))
        check(Census(
            "UpstreamTLSInfo → get_flow_detail.transport.upstreamTLS",
            model: tls,
            render: RenderedUpstreamTLS(tls)!
        ))
        check(Census(
            "PeerCertificateInfo → get_flow_detail.transport.upstreamTLS.certificate",
            model: certificate,
            render: RenderedPeerCertificate(certificate)!
        ))
    }

    @Test func capturedRequest_carriesEveryModelField() {
        let request = CapturedRequest(method: "GET", url: "https://a.test", headers: [])
        check(Census(
            "CapturedRequest → get_flow_detail.request",
            model: request,
            render: RenderedRequest(request, body: .text("")),
            accountedFor: [
                "fullBodyBytes": "renamed: `bodyCaptureTruncated` + `bodyBytesOnWire`, which say *why* the number is there",
            ]
        ))
    }

    @Test func capturedResponse_carriesEveryModelField() {
        let response = CapturedResponse(statusCode: 200, headers: [])
        check(Census(
            "CapturedResponse → get_flow_detail.response",
            model: response,
            render: RenderedResponse(response, body: .text("")),
            accountedFor: [
                "statusCode": "renamed to `status`, matching the summary's key for the same number",
                "fullBodyBytes": "renamed: `bodyCaptureTruncated` + `bodyBytesOnWire`",
            ]
        ))
    }

    @Test func sourceAttribution_carriesEveryModelField() {
        let app = SourceApp(name: "curl", pid: 1)
        check(Census(
            "SourceApp → flow.sourceApp",
            model: app,
            render: SourceAppRender(app),
            accountedFor: [
                "bundlePath": "deliberately absent: a filesystem path for the human's icon lookup, of no use to an agent and a needless disclosure",
            ]
        ))

        let device = SourceDevice(ip: "127.0.0.1", kind: .local)
        check(Census("SourceDevice → flow.sourceDevice", model: device, render: SourceDeviceRender(device)))
    }

    @Test func graphQL_carriesEveryModelField() {
        let operation = GraphQLOperation(kind: .query, operationName: "Q", query: "{ a }", variablesJSON: nil)
        check(Census(
            "GraphQLOperation → get_flow_detail.graphQL",
            model: operation,
            render: RenderedGraphQL(operation),
            accountedFor: [
                "variablesJSON": "renamed to `variables` — it is already JSON text, and the suffix said so twice",
            ]
        ))
    }

    @Test func flowDetail_showsTheAgentBothProtocolsAndTheConnection() throws {
        // The end-to-end reading, not just the census: a census proves a field
        // exists on a render type, and what matters is that `get_flow_detail`'s
        // JSON carries it. The two `httpVersion`s in particular have to sit on
        // opposite sides — an agent reading only the response's would conclude an
        // h2 client spoke HTTP/1.1.
        let flow = Flow(
            request: CapturedRequest(
                method: "GET", url: "https://api.example.test/v1", httpVersion: "HTTP/2", headers: []
            ),
            startedAt: Date(timeIntervalSince1970: 0),
            outcome: .completed(
                CapturedResponse(statusCode: 200, httpVersion: "HTTP/1.1", headers: []),
                at: Date(timeIntervalSince1970: 1)
            ),
            transport: FlowTransport(
                remoteAddress: "93.184.216.34:443",
                connectionReused: true,
                upstreamTLS: UpstreamTLSInfo(
                    version: "TLSv1.3", serverName: "api.example.test",
                    certificate: PeerCertificateInfo(issuer: "CN=Test CA")
                ),
                responseContentEncoding: "gzip",
                responseEncodedBodyBytes: 640
            )
        )
        let rendered = MCPToolExecutor.flowDetail(flow, offset: 0, maxBytes: 4_096)

        #expect((rendered["request"] as? [String: Any])?["httpVersion"] as? String == "HTTP/2")
        #expect((rendered["response"] as? [String: Any])?["httpVersion"] as? String == "HTTP/1.1")
        let transport = try #require(rendered["transport"] as? [String: Any])
        #expect(transport["remoteAddress"] as? String == "93.184.216.34:443")
        #expect(transport["connectionReused"] as? Bool == true)
        #expect(transport["responseEncodedBodyBytes"] as? Int == 640)
        let tls = try #require(transport["upstreamTLS"] as? [String: Any])
        #expect(tls["version"] as? String == "TLSv1.3")
        #expect((tls["certificate"] as? [String: Any])?["issuer"] as? String == "CN=Test CA")
    }

    @Test func flowDetail_omitsTheTransportWhenNothingTouchedASocket() {
        // A mocked or blocked exchange. An empty `transport` object would tell an
        // agent the connection was measured and had nothing to report, which is a
        // different (and wrong) answer from "there was no connection".
        let rendered = MCPToolExecutor.flowDetail(flow, offset: 0, maxBytes: 4_096)
        #expect(rendered["transport"] == nil)
    }

    // MARK: - Flow diff
    //
    // `diff_flows` was the last agent-facing render still hand-building a
    // `[String: Any]`, i.e. the last one where adding a model field compiled
    // everywhere and the agent silently never saw it. These are the census entries
    // that close it.

    @Test func flowDiff_carriesEveryModelField() {
        let comparison = FlowComparison(
            baseID: UUID(),
            comparedID: UUID(),
            request: FlowComparison.MessageComparison(),
            response: FlowComparison.ResponseComparison()
        )
        check(Census(
            "FlowComparison → diff_flows",
            model: comparison,
            render: FlowDiffRender(comparison),
            accountedFor: [
                "baseID": "renamed to `baseId`, matching every other id key an agent reads",
                "comparedID": "renamed to `comparedId`",
            ]
        ))
    }

    @Test func flowDiffPieces_carryEveryModelField() {
        let message = FlowComparison.MessageComparison()
        check(Census(
            "FlowComparison.MessageComparison → diff_flows.request",
            model: message,
            render: MessageDiffRender(message)
        ))

        let response = FlowComparison.ResponseComparison()
        check(Census(
            "FlowComparison.ResponseComparison → diff_flows.response",
            model: response,
            render: ResponseDiffRender(response),
            accountedFor: [
                "presence": "renamed to `present` — the key holds the two booleans, not the concept",
            ]
        ))

        let change = FlowComparison.ValueChange(base: "a", compared: "b")
        check(Census(
            "FlowComparison.ValueChange → every {base, compared} pair",
            model: change,
            render: ValueChangeRender(change)
        ))

        let header = FlowComparison.HeaderChange(name: "Accept", base: ["a"], compared: ["b"])
        check(Census(
            "FlowComparison.HeaderChange → diff_flows headers.changed[]",
            model: header,
            render: HeaderDiffRender.Changed(name: header.name, base: ["a"], compared: ["b"])
        ))
    }

    @Test func bodyDiff_carriesEveryModelField() {
        let body = FlowComparison.BodyComparison(
            baseBytes: 1, comparedBytes: 2, baseWireBytes: 3, comparedWireBytes: 4, detail: .binary
        )
        check(Census(
            "FlowComparison.BodyComparison → diff_flows body block",
            model: body,
            render: BodyDiffRender(body),
            accountedFor: [
                "baseWireBytes": "renamed to `baseBytesOnWire`, the vocabulary get_flow_detail already uses for the same fact",
                "comparedWireBytes": "renamed to `comparedBytesOnWire`",
                "detail": "folded: the sum type becomes `binary` / `tailNotCompared` / `lineDiffSkipped`+line counts / added+removedLines",
            ]
        ))
    }

    @Test func webSocketDiff_carriesEveryModelField() {
        let webSocket = FlowComparison.WebSocketComparison(
            presence: FlowComparison.ValueChange(base: true, compared: false)
        )
        check(Census(
            "FlowComparison.WebSocketComparison → diff_flows.webSocket",
            model: webSocket,
            render: WebSocketDiffRender(webSocket),
            accountedFor: [
                "presence": "renamed to `present`",
                "droppedMessages": "renamed to `framesNotRecorded`, matching get_flow_detail.webSocket",
                "captureError": "renamed to `captureStopped`, matching get_flow_detail.webSocket",
            ]
        ))
    }

    // MARK: - Stats

    @Test func statsBucket_carriesEveryModelField() {
        check(Census(
            "FlowStats.Bucket → get_stats.buckets[]",
            model: bucket,
            render: StatsBucketRender(bucket),
            accountedFor: [
                "ttfb": "renamed to `ttfbMS`: the render names its unit, because an agent reading a bare number has to guess",
                "receive": "renamed to `receiveMS`",
                "duration": "renamed to `durationMS`",
            ]
        ))
    }

    @Test func statsDistribution_carriesEveryModelField() {
        let distribution = FlowStats.Distribution(p50: 1, p95: 2, max: 3, samples: 4)
        check(Census(
            "FlowStats.Distribution → get_stats ttfbMS/receiveMS/durationMS",
            model: distribution,
            render: DistributionRender(distribution)
        ))
    }

    // MARK: - Breakpoints

    @Test func breakpoint_carriesEveryModelField() {
        let breakpoint = Breakpoint(match: RuleMatch(urlPattern: "*"))
        check(Census(
            "Breakpoint → list_pending.armed[]",
            model: breakpoint,
            render: BreakpointRender(
                id: breakpoint.id.uuidString,
                match: RuleMatchRender(breakpoint.match),
                onRequest: breakpoint.onRequest,
                onResponse: breakpoint.onResponse,
                createdAt: breakpoint.createdAt,
                comment: breakpoint.comment
            )
        ))
    }

    @Test func ruleMatch_carriesEveryModelField() {
        let match = RuleMatch(urlPattern: "*")
        check(Census(
            "RuleMatch → the `match` block",
            model: match,
            render: RuleMatchRender(match),
            accountedFor: [
                "style": "renamed to `matchStyle` — one always-present key instead of the two optional booleans it replaced",
            ]
        ))
    }

    @Test func pendingBreakpoint_carriesEveryModelField() {
        let pending = pending
        check(Census(
            "PendingBreakpoint → list_pending.pending[]",
            model: pending,
            render: PendingBreakpointRender(
                id: pending.id.uuidString,
                breakpointId: pending.breakpointID.uuidString,
                phase: pending.phase.rawValue,
                heldAt: pending.heldAt,
                request: PendingRequestRender(
                    method: pending.method, url: pending.url,
                    headers: [], body: .text("")
                ),
                response: nil
            ),
            accountedFor: [
                "breakpointID": "cased as `breakpointId` — JSON keys here are lowerCamel throughout, and `ID` would be the only shout",
                "method": "nested under `request`, where a held exchange's request belongs",
                "url": "nested under `request`",
                "requestHeaders": "nested as `request.headers`",
                "requestBody": "nested as `request.body`, through the same body window a flow's uses",
                "statusCode": "nested as `response.status`, and only in the response phase",
                "responseHeaders": "nested as `response.headers`",
                "responseBody": "nested as `response.body`",
            ]
        ))
    }

    // MARK: - Environment

    @Test func proxyStatus_carriesEveryModelField() {
        let status = ProxyStatus(isRunning: true, port: 9090, capturedCount: 0)
        check(Census(
            "ProxyStatus → get_proxy_status",
            model: status,
            render: ProxyStatusRender(
                isRunning: status.isRunning, port: status.port, listenHost: status.listenHost,
                lanReachable: status.isLANReachable, capturedCount: status.capturedCount,
                flowsRetained: status.retainedCount,
                isRecording: status.isRecording, socksPort: status.socksPort,
                systemProxy: "unavailable"
            ),
            accountedFor: [
                "retainedCount": "renamed to `flowsRetained`, matching what `get_stats` already calls the same number — one name for one quantity beats a second one an agent has to learn",
            ]
        ))
    }

    @Test func connectionRefusal_carriesEveryModelField() {
        let refusal = ConnectionRefusal(listener: .socks, reason: "SOCKS4 is not supported")
        check(Census(
            "ConnectionRefusal → get_proxy_status.recentRefusals[]",
            model: refusal,
            render: ConnectionRefusalRender(refusal),
            accountedFor: [
                "id": "deliberately absent: a refusal is read as a list, never addressed individually — there is no tool that takes one",
            ]
        ))
    }

    @Test func reverseProxy_carriesEveryModelField() {
        let status = ReverseProxyStatus(
            endpoint: ReverseProxyEndpoint(requestedPort: 0, upstream: "https://api.example.test"),
            boundPort: 8080
        )
        check(Census(
            "ReverseProxyStatus → list_reverse_proxies[]",
            model: status,
            render: ReverseProxyRender(status),
            accountedFor: [
                "endpoint": "flattened: the endpoint's own fields are censused below, and a nested object here would make the common read two levels deep for no gain",
                "boundPort": "folded into `listening` + `localURL`, which is the form the caller pastes into a config file",
            ]
        ))

        let endpoint = ReverseProxyEndpoint(requestedPort: 0, upstream: "https://api.example.test")
        check(Census(
            "ReverseProxyEndpoint → the same render, flattened",
            model: endpoint,
            render: ReverseProxyRender(ReverseProxyStatus(endpoint: endpoint, boundPort: nil)),
            accountedFor: [
                "requestedPort": "folded: what matters is the port actually bound (`localURL`), and `0` means \"any free port\" rather than a place to connect to",
                "createdAt": "deliberately absent: an endpoint is config, not an event — nothing an agent decides turns on when it was made",
            ]
        ))
    }

    @Test func deviceSummary_carriesEveryModelField() {
        let summary = DeviceSummary(
            device: SourceDevice(ip: "192.168.1.10", kind: .lan), flowCount: 3,
            lastActive: Date(timeIntervalSince1970: 0)
        )
        check(Census(
            "DeviceSummary → list_devices[]",
            model: summary,
            render: DeviceSummaryRender(summary),
            accountedFor: [
                "device": "flattened: its fields (ip/kind/platform/client) are lifted to the top level, where a device row reads as one thing",
            ]
        ))
    }

    @Test func certificateStatus_carriesEveryModelField() {
        let status = CertificateStatus.notGenerated
        check(Census(
            "CertificateStatus → get_certificate_status",
            model: status,
            render: CertificateStatusRender(status)
        ))
    }

    @Test func sslScope_carriesEveryModelField() {
        let scope = SSLScope.disabled
        check(Census("SSLScope → get_ssl_scope", model: scope, render: SSLScopeRender(scope)))
    }

    @Test func tunneledHost_carriesEveryModelField() {
        let entry = TunneledHost(host: "gradle.example.test", port: 443, firstSeen: Date(timeIntervalSince1970: 0), lastSeen: Date(timeIntervalSince1970: 1), reason: .excluded)
        check(Census(
            "TunneledHost → get_ssl_scope.tunneledHosts[]",
            model: entry,
            render: TunneledHostRender(entry)
        ))
    }

    @Test func clientCertificate_carriesEveryModelField() {
        let summary = ClientCertificateSummary(
            id: UUID(), hostPattern: "*.example.test", label: "staging", isEnabled: true
        )
        check(Census(
            "ClientCertificateSummary → list_client_certificates[]",
            model: summary,
            render: ClientCertificateRender(summary),
            accountedFor: [
                "isEnabled": "renamed to `enabled` — the `is` prefix is a Swift convention, not a JSON one",
            ]
        ))
    }

    @Test func auditEntry_carriesEveryModelField() {
        let entry = AuditEntry(tool: "set_rule", succeeded: true, arguments: "{}", detail: "")
        check(Census(
            "AuditEntry → get_audit_log[]",
            model: entry,
            render: AuditEntryRender(entry)
        ))
    }

    // MARK: - Protocol traffic

    @Test func protocolTraffic_carriesEveryModelField() {
        let log = MCPEraLog()
        log.record(reason: .modernMeta, client: MCPClientIdentity(["name": "c"]))
        let snapshot = log.snapshot()
        check(Census(
            "MCPEraLog.Snapshot → get_version.protocolTraffic",
            model: snapshot,
            render: ProtocolTrafficRender(snapshot),
            accountedFor: [
                "counts": "flattened into the three numbers a reader acts on: `modernRequests` (both modern reasons summed), `legacyHandshakes` (the evidence), `legacyBareRequests` (deliberately not evidence). A raw per-reason map would make the caller re-derive that distinction, which is the one thing this type exists to prevent them getting wrong",
            ]
        ))

        let client = try? #require(snapshot.modernClients.first)
        if let client {
            check(Census(
                "MCPEraLog.Client → protocolTraffic.modernClients[]",
                model: client,
                render: ProtocolClientRender(client)
            ))
        }
    }

    // MARK: - Rules
    //
    // `RuleCodecParityTests` already censuses the rule against its *input schema*.
    // This is the other side: the render an agent reads back.

    @Test func rule_carriesEveryModelField() {
        let rule = TrafficRule(name: "r", match: RuleMatch(urlPattern: "*"), actions: RuleActions())
        check(Census(
            "TrafficRule → list_rules[]",
            model: rule,
            render: RuleRender(rule, truncateBodies: true),
            accountedFor: [
                "isEnabled": "renamed to `enabled`",
            ]
        ))
    }

    @Test func ruleActions_carryEveryModelField() {
        let actions = RuleActions()
        check(Census(
            "RuleActions → list_rules[].actions",
            model: actions,
            render: RuleActionsRender(actions, truncateBodies: true),
            accountedFor: [
                "route": "the sum type is flattened into its cases (`block` / `mockResponse` / `mapRemote` / `mapLocal`), exactly one of which appears; `passthrough` is the absence of all four",
                "delayMilliseconds": "renamed to `delayMs`, matching the `delay_ms` an agent writes",
            ]
        ))
    }

    @Test func ruleActionPayloads_carryEveryModelField() {
        let mock = MockResponseAction(statusCode: 200, headers: [])
        check(Census(
            "MockResponseAction → actions.mockResponse",
            model: mock,
            render: MockResponseRender(mock, truncateBodies: true),
            accountedFor: [
                "body": "split by kind: `MockBody.text` renders as `body` (+ `bodyLength`/`bodyTruncated` when a list render cuts it), `.bytes` as `bodyBase64`",
            ]
        ))

        let mapRemote = MapRemoteAction(destination: "https://staging.example.test")
        check(Census(
            "MapRemoteAction → actions.mapRemote",
            model: mapRemote,
            render: MapRemoteRender(mapRemote),
            accountedFor: ["excludePattern": "renamed to `exclude`"]
        ))

        let mapLocal = MapLocalAction(path: "/tmp/x.json")
        check(Census("MapLocalAction → actions.mapLocal", model: mapLocal, render: MapLocalRender(mapLocal)))

        let request = RequestRewriteAction()
        check(Census(
            "RequestRewriteAction → actions.rewriteRequest",
            model: request,
            render: RequestRewriteRender(request, truncateBodies: true),
            accountedFor: [
                "body": "split by kind: `RewriteBody.text` renders as `body` (+ `bodyLength` / `bodyTruncated`), `.file` as `bodyFile`",
            ]
        ))

        let response = ResponseRewriteAction()
        check(Census(
            "ResponseRewriteAction → actions.rewriteResponse",
            model: response,
            render: ResponseRewriteRender(response, truncateBodies: true),
            accountedFor: ["bodyText": "renamed to `body` (+ `bodyLength` / `bodyTruncated`)"]
        ))

        let substitution = SubstitutionRule(field: .body, match: "a", replacement: "b")
        check(Census(
            "SubstitutionRule → actions.requestSubstitutions[]",
            model: substitution,
            render: SubstitutionRender(substitution),
            accountedFor: [
                "id": "deliberately absent: substitutions are written and read as an ordered list on their rule — there is no tool that addresses one, so an id would be a handle to nothing",
            ]
        ))
    }

    // MARK: - The encoding contract itself

    /// The three body shapes must stay distinguishable: an agent has to be able to
    /// tell "no body" from "2 MB of PNG" from "the first 16 KB of a large JSON".
    @Test func renderedBody_keepsTheThreeShapesApart() throws {
        // No body renders as an empty string, not as an object and not as null:
        // "there was no body" is an answer, and it has always been spelled `""`.
        #expect(MCPRender.dict(Wrapper(body: MCPToolExecutor.bodyField(nil)))["body"] as? String == "")

        let text = MCPRender.dict(Wrapper(body: MCPToolExecutor.bodyField(Data("hi".utf8))))
        #expect(text["body"] as? String == "hi")

        let binary = MCPRender.dict(Wrapper(body: MCPToolExecutor.bodyField(Data([0xFF, 0xFE, 0xFD]))))
        let binaryBody = try #require(binary["body"] as? [String: Any])
        #expect(binaryBody["binary"] as? Bool == true)
        #expect(binaryBody["bytes"] as? Int == 3)

        let windowed = MCPRender.dict(Wrapper(body: MCPToolExecutor.bodyField(Data("abcdef".utf8), offset: 1, maxBytes: 2)))
        let window = try #require(windowed["body"] as? [String: Any])
        #expect(window["truncated"] as? Bool == true)
        #expect(window["preview"] as? String == "bc")
        #expect(window["bytes"] as? Int == 6)
        #expect(window["offset"] as? Int == 1)
        #expect(window["nextOffset"] as? Int == 3)
    }

    /// A nil optional must be *absent*, not `null`: every render field is documented
    /// as "omitted when it doesn't apply", and a null would make an agent's
    /// `if "error" in flow` read true on a flow that succeeded.
    @Test func nilFields_areOmittedRatherThanNull() {
        let rendered = MCPToolExecutor.flowSummary(flow)
        #expect(rendered["error"] == nil)
        #expect(rendered["status"] == nil)
        #expect(rendered["sourceApp"] == nil)
        #expect(rendered["captureTruncated"] == nil)
        #expect(rendered.keys.contains("id"))
    }

    /// Timestamps stay ISO-8601 without fractional seconds — the format
    /// `get_recent_flows` has always emitted and `since` parses back.
    @Test func datesEncodeAsISO8601() {
        var flow = flow
        flow.startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(MCPToolExecutor.flowSummary(flow)["startedAt"] as? String == "2023-11-14T22:13:20Z")
    }

    private struct Wrapper: Encodable {
        var body: RenderedBody
    }
}
