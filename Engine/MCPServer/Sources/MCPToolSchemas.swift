import Foundation
import LoomSharedModels

/// One tool, whole: what `tools/list` advertises about it, what running it does,
/// and whether running it is a write action.
///
/// These four facts used to live in four places keyed by the tool's name as a
/// string — a definition here, a handler function in `MCPTools+<domain>`, an entry
/// in a `[String: handler]` dictionary, and a name in a `Set<String>` of write
/// tools. Three tests existed to catch a typo or an omission across them, which is
/// the tell: the compiler could not, because nothing tied the copies together.
/// Bundling them into one value means the alignment is structural — a tool cannot
/// be advertised without a handler, dispatched without a definition, or silently
/// escape auditing, because there is only one place to write it down.
///
/// `isWrite` is a field rather than a search for the "This is a write action."
/// marker in the description for the reason the old `writeTools` set gave: a typo
/// in prose must not be able to switch auditing off. The marker still has to be
/// *present* (a test pins description and flag together), because it is what tells
/// the agent, but the flag is what the audit choke point reads.
///
/// **Plainly `Sendable`**, which it could not be while `inputSchema` was a
/// `[String: Any]`: the dictionary held only JSON literals and was never mutated,
/// but the `Any` was unprovable, so the type carried `@unchecked Sendable` and the
/// annotation said nothing about what a future edit could break. `JSONSchema` is a
/// checked value type, so the compiler answers the question now — and the `Any`
/// survives only at the serialization boundary (`definition`), which is where
/// `JSONSerialization` needs it.
struct MCPTool: Sendable {
    let name: String
    let description: String
    let inputSchema: JSONSchema
    /// Touches real traffic, so `MCPToolExecutor.call` records it in the audit trail.
    let isWrite: Bool
    let handler: @Sendable (MCPToolExecutor, MCPArguments) async throws -> String

    init(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        isWrite: Bool = false,
        handler: @escaping @Sendable (MCPToolExecutor, MCPArguments) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.isWrite = isWrite
        self.handler = handler
    }

    /// The `tools/list` JSON for this tool.
    var definition: [String: Any] {
        ["name": name, "description": description, "inputSchema": inputSchema.json]
    }
}

/// What `tools/list` advertises: every tool's name, description and JSON input
/// schema, plus the shared sub-schemas (`match`, `actions`, the flow filter).
///
/// Kept apart from the handler bodies in `MCPTools+<domain>` because the two answer
/// different questions — "what can an agent ask for" versus "what happens when it
/// does" — and because this is the surface an agent reads before it ever calls
/// anything, so it is worth being able to read end to end. The *pairing* is no
/// longer a matter of trust: each entry below carries its own handler.
extension MCPToolExecutor {
    /// The flow-filter arguments, shared verbatim by `get_recent_flows`,
    /// `wait_for_flow` and `get_stats` — one filter vocabulary, parsed by one
    /// `flowQuery(from:)`, so they can't drift into subtly different notions of
    /// "matching". A tool adds its own arguments with `.adding`, which refuses to
    /// shadow one of these.
    ///
    /// No `nonisolated(unsafe)` any more: `JSONSchema` is a checked `Sendable` value,
    /// so this is an ordinary immutable static.
    static let flowFilterProperties: [String: JSONSchema] = [
        "host": .string("Host, exact or glob: `api.example.com`, `*.example.com`."),
        "method": .oneOf(
            [.string(), .array(of: .string())],
            description: "HTTP method(s) to include, case-insensitive. A string or an array of strings."
        ),
        "url_contains": .string("Case-insensitive substring of the full URL (path, query, …)."),
        "header_contains": .string("""
            Case-insensitive substring of a header. Plain text matches a header name or \
            value (`authorization`, `Bearer ey`); with a colon it means `name: value` and \
            both halves must hit the same header (`x-env: staging`, or `set-cookie:` for \
            "has this header at all"). Searches both sides unless `header_in` narrows it.
            """),
        "header_in": .string(
            """
            Which side `header_contains` searches; default `any`. Most header questions \
            have a side — "who sent this auth header" is about requests, "who set this \
            cookie" is about responses — and searching both buries the answer.
            """,
            allowed: ExchangeSide.allCases.map(\.rawValue)
        ),
        "body_contains": .string("""
            Case-insensitive substring of a captured body — the "which exchange carried \
            this id/token/error string" filter. Matched over raw bytes, so non-UTF-8 \
            payloads are searched too. Searches both sides unless `body_in` narrows it. \
            Combine with `host` / `url_contains` / `since_seconds` to keep the scan \
            narrow, and note a flow with `captureTruncated: true` holds only a body \
            prefix, so a miss on one of those isn't proof.
            """),
        "body_in": .string(
            """
            Which side `body_contains` searches; default `any`. Use `request` for the \
            usual question — "which request carried this order id" — because a list \
            endpoint's *response* typically contains every id in the system, so searching \
            both returns a page of noise around the one hit you wanted.
            """,
            allowed: ExchangeSide.allCases.map(\.rawValue)
        ),
        "status": .oneOf(
            [.integer(), .string()],
            description: "Status code: an exact number (500) or a class as a string (\"5xx\", \"4xx\")."
        ),
        "status_min": .integer("Lowest status code to include (inclusive)."),
        "status_max": .integer("Highest status code to include (inclusive)."),
        "only_errors": .boolean("Only failures: a transport error or status >= 400 (in-flight flows are excluded)."),
        "since_seconds": .number("Only flows started within the last N seconds — the usual way to isolate \"what I just triggered\"."),
        "since": .string("Only flows started at/after this ISO-8601 timestamp (alternative to `since_seconds`)."),
        "device_ip": .string("Only traffic from this device IP (see list_devices)."),
        "source_app": .string("Only traffic from this local app, by bundle id or display name."),
    ]

    /// The shared filter as an object node, for the tools that take it plus a few
    /// arguments of their own.
    static let flowFilterSchema: JSONSchema = .object(flowFilterProperties)

    /// JSON metadata advertised by `tools/list`, derived from the one table.
    var toolDefinitions: [[String: Any]] { Self.tools.map(\.definition) }

    /// The tool surface: one value per tool, carrying everything that used to be
    /// aligned by hand across four places — the advertised definition, the
    /// handler, and whether the call is a write action (and so audited).
    static let tools: [MCPTool] = [
        MCPTool(
            name: "get_version",
            description: """
            Get the Loom app version and MCP protocol version. Cheap readiness ping — if this \
            errors, the app isn't running and no other tool will work either.

            `appVersion` is also the skew check: the tools you can call come from the app, their \
            prose from whatever plugin version is installed, so compare it against the version in \
            the loom plugin's own manifest. Older app → tell the user to update Loom (panel footer \
            → Update), because tools the skill describes may not exist yet. Newer app → tell them \
            to run `/plugin update loom`, because tools you can call aren't documented there. \
            Either way it is a stale *description*, never a broken connection — `tools/list` is \
            the truth about what exists — so say it once, name which side is behind, carry on, \
            and don't block work on it.
            
            `protocolTraffic` reports which MCP revision the requests reaching this endpoint \
            actually spoke this run, and which clients spoke them. Loom serves two revisions at \
            once; the old one is only kept because a legacy client cannot fall forward. \
            `legacyEra` is three-valued on purpose, with `legacyEraReason` saying why: `blocked` \
            (an `initialize` handshake was seen — that handshake is the old revision's, so it \
            proves an old client exists, and `legacyClients` names it), `unknown` (no handshake, \
            but nothing negotiated the modern revision either — the tally is per-launch, so this \
            is the absence of evidence, not evidence of absence), `retirable` (no handshake and \
            modern traffic actually negotiated). Never report `unknown` as good news. \
            `legacyBareRequests` counts requests that declared no revision at all and is \
            deliberately *not* evidence: a stripped header or a hand-typed curl looks the same. \
            Absent entirely when nothing is counting (the engine embedded without a server).
            """,
            inputSchema: .object(),
            handler: { ex, args in try await ex.handleGetVersion(args) }
        ),
        MCPTool(
            name: "get_proxy_status",
            description: """
            Get the current proxy status: running state, listen address, captured flow count, \
            whether recording is paused, and whether this Mac's own traffic is actually routed \
            through Loom (`systemProxy`). Check this first when a capture comes back empty — \
            "nothing happened" and "nothing was pointed at the proxy" look identical otherwise.

            Two counts, and reading the wrong one is how a busy capture looks stalled. \
            `capturedCount` is the in-memory ring, which is small and **plateaus at its cap** — \
            once it is full it reports the same number forever, however much traffic arrives. \
            `flowsRetained` is everything still on disk, an order of magnitude more, and it is \
            what every other read is scoped by: `get_recent_flows`, `get_flow_detail`, \
            `diff_flows` and `replay_flow` all resolve against it. Use `flowsRetained` to answer \
            "how much has been captured"; it is absent only when this build persists nothing.

            `systemProxy` is one of: `"on"` (routed through Loom), `"off"` (no system proxy set), \
            `"other"` (another proxy app — Charles, Proxyman, whistle — owns the setting; \
            `systemProxyPointsAt` gives its host:port), or `"unavailable"` (this build can't \
            inspect it, which is not the same as off). On `"other"`, say so rather than calling \
            `set_system_proxy`: taking the setting works, but Loom never puts the other app's \
            configuration back, so that is the human's call.

            `listenHost` / `lanReachable` answer a second empty-capture case the ports alone \
            cannot: `127.0.0.1` means the listener is loopback-only, so a phone or any other \
            device on the Wi-Fi cannot reach it however correctly it is configured — the \
            connection is refused before Loom is involved, and nothing is recorded. \
            `lanReachable` is true only when it is bound to `0.0.0.0`. If a LAN device sent \
            nothing, read this before anything else.

            Two fields appear only when non-empty. `refusedConnections` / `recentRefusals`: a \
            client that reached Loom and was turned away (a SOCKS4 client, an HTTP request sent to \
            the SOCKS port, an unsupported command) looks exactly like a client that never ran, \
            and this is the difference. `reverseProxies`: the local stand-in ports and whether \
            each is listening — one that is not carries `error`, and a client pointed at it gets \
            connection refused, which reads like Loom is down.
            """,
            inputSchema: .object(),
            handler: { ex, args in try await ex.handleGetProxyStatus(args) }
        ),
        MCPTool(
            name: "set_system_proxy",
            description: """
            Route this Mac's HTTP/HTTPS traffic through Loom, or stop routing it. This is what \
            makes local apps and browsers appear in the capture without configuring each one, \
            and the fix when `get_proxy_status` shows nothing is routed here. A phone or other \
            device does NOT need this — point that device at the proxy instead.

            Machine-wide and visible to the human: it edits the active network service's proxy \
            settings, may ask for an admin password, and installs a pf rule blocking QUIC (UDP \
            443) so browsers fall back to TCP where a proxy can see them (they default to HTTP/3, \
            which no TCP proxy can intercept). Turn it off when done; Loom also does so on quit. \
            Disabling never hands the setting back to whoever held it before — if \
            `get_proxy_status` reported `"other"`, say so and let the human re-enable that app.

            It routes the *machine*, not processes already running (`runningClientsMayNeedRelaunch` \
            says so). Chrome and other Chromium/Electron apps read the system proxy once at launch, \
            so one already open keeps going direct — reloading does not help, only relaunching. An \
            empty capture right after turning this on is usually that, not an absence of traffic. \
            Safari, curl and most CLI tools need no restart.

            Two destinations the client bypasses whatever this setting says: \
            `localhost`/`127.0.0.1`, and (in Safari) any address belonging to this Mac. For a \
            local dev server reached by IP, relaunching Chrome is enough; over loopback, use \
            `create_reverse_proxy` instead — the client connects straight to Loom's port, so no \
            proxy setting is consulted. This is a write action.
            """,
            inputSchema: .object(
                [
                    "enabled": .boolean("true = route this Mac through Loom, false = turn the system proxy off (NOT restore a previous owner's settings)."),
                ],
                required: ["enabled"]
            ),
            isWrite: true,
            handler: { ex, args in try await ex.handleSetSystemProxy(args) }
        ),
        MCPTool(
            name: "list_reverse_proxies",
            description: """
            List the reverse-proxy endpoints: local ports that stand in for an upstream origin. \
            Each reports `localURL` (what to point a client at) and `listening`; an endpoint that \
            is not listening carries `error` explaining why (usually its port is taken), and a \
            client aimed at it gets connection refused rather than reaching Loom.
            """,
            inputSchema: .object(),
            handler: { ex, args in try await ex.handleListReverseProxies(args) }
        ),
        MCPTool(
            name: "create_reverse_proxy",
            description: """
            Open a local port that stands in for `upstream`, capturing everything sent to it. \
            Use it for a client that CANNOT be pointed at a proxy — in practice a Node dev server \
            forwarding `/api` to a backend, because Node's global `fetch`/undici ignores \
            `HTTP_PROXY` entirely, so that hop is invisible however the environment is set (axios \
            and Python/Go clients do read it and need no endpoint). Rather than patching the \
            client's source, change its target to this endpoint's `localURL`.

            Two things this buys over the proxy ports: the inbound hop is plain HTTP even when \
            `upstream` is https, so the client needs NO CA trust (no NODE_EXTRA_CA_CERTS, no \
            keychain step) — Loom does the upstream TLS itself; and the captured flow carries the \
            UPSTREAM url, not 127.0.0.1, so rules, breakpoints and diff_flows match it like any \
            other traffic.

            The endpoint survives relaunch, since its port lives in a dev server's config Loom \
            does not edit. It is NOT a proxy port: send it paths directly (GET /api/users), not \
            CONNECT or absolute URLs. Creation fails if the upstream is not a valid http(s) origin \
            or the port cannot be bound — it never reports an endpoint that isn't listening. This \
            is a write action.
            """,
            inputSchema: .object(
                [
                    "upstream": .string(
                        "Origin to forward to, e.g. https://api.example.com. A base path is allowed (https://api.example.com/v2) and is prefixed to each request's path. No query or fragment."
                    ),
                    "port": .integer(
                        "Local port to listen on. Omit or 0 to let the OS pick a free one — but a dev server's config names a fixed port, so usually pin it."
                    ),
                    "label": .string("Optional note: which project or scenario this endpoint is for."),
                    "keep_host_header": .boolean(
                        "Keep the client's Host header (127.0.0.1:port) instead of rewriting it to the upstream host. Default false — a real server usually vhost-routes on Host, and sending it 127.0.0.1 yields a 404 that looks like Loom broke the request."
                    ),
                ],
                required: ["upstream"]
            ),
            isWrite: true,
            handler: { ex, args in try await ex.handleCreateReverseProxy(args) }
        ),
        MCPTool(
            name: "delete_reverse_proxy",
            description: """
            Close a reverse-proxy endpoint and forget it (see list_reverse_proxies for ids). \
            Any client still pointed at that port will get connection refused afterwards, so \
            check whether a dev server config still names it. This is a write action.
            """,
            inputSchema: .object(
                ["id": .string("Endpoint UUID from list_reverse_proxies.")],
                required: ["id"]
            ),
            isWrite: true,
            handler: { ex, args in try await ex.handleDeleteReverseProxy(args) }
        ),
        MCPTool(
            name: "list_devices",
            description: "List devices that have sent traffic through the proxy — this Mac plus any LAN devices (e.g. phones), each with detected platform/client (from User-Agent), flow count, and last-seen time.",
            inputSchema: .object(),
            handler: { ex, args in try await ex.handleListDevices(args) }
        ),
        MCPTool(
            name: "get_recent_flows",
            description: """
            List captured HTTP flows, newest first, with method, url, status, timing and startedAt. \
            Filters (all optional, ANDed) are applied across every retained flow BEFORE `limit`, \
            so a match that isn't among the newest exchanges is still found — prefer filtering here \
            over pulling a big list and scanning it yourself. "Retained" means memory **and** the \
            durable store on disk, which holds an order of magnitude more, so a filter reaches \
            exchanges captured long before this session. Exchanges older than that store's row cap \
            are pruned and no filter will find them; `get_stats` reports `flowsRetained` if you need \
            the denominator. `captureTruncated: true` on a summary means the recorded body/frame \
            log is only a prefix of what actually flowed, so a `body_contains` miss on one of those \
            isn't proof.
            """,
            inputSchema: Self.flowFilterSchema.adding([
                "limit": .integer("Max flows to return after filtering (default 20)."),
            ]),
            handler: { ex, args in try await ex.handleGetRecentFlows(args) }
        ),
        MCPTool(
            name: "wait_for_flow",
            description: """
            Block until a flow matching the filters is captured, then return it — the \
            "trigger the action, then see the request it made" tool. Takes the same filters as \
            `get_recent_flows`, so you never poll it in a loop.

            It is a query over the retained capture *and* a wait, in that order: stored flows are \
            checked first, so a request triggered a moment before calling returns immediately. \
            Nothing is lost on a timeout at any layer — the flow stays in the store, and calling \
            again with `since` set to the previous reply's `windowFrom` finds it with no gap.

            Returns `{matched: [...summaries], timedOut, waitedMS, windowFrom}`. The default \
            window is the last \(Int(Self.defaultWaitLookback)) seconds (not "from now on", so \
            the trigger-then-call sequence can't race); pass `since_seconds` or `since` to widen \
            or pin it.
            """,
            inputSchema: Self.flowFilterSchema.adding([
                "max_seconds": .number("""
                    How long to wait before giving up (default \(Self.defaultWaitSeconds), \
                    max \(Self.maxWaitSeconds)). A timeout is a normal result, not an error: \
                    `timedOut: true` with an empty `matched`.
                    """),
                "until": .string(
                    """
                    How much of the exchange to wait for. `completed` (default) = it finished \
                    or failed, so status, timing and both bodies are final. `response` = the \
                    status line is known but the body may still be streaming — use this for a \
                    WebSocket (the 101 upgrade), which otherwise never completes while the \
                    socket is open, or for a long download. `request` = return the moment the \
                    request is seen, before any response exists.
                    """,
                    // The one enum list still written out: `WaitUntil`'s declaration
                    // order is request-first, and this list is deliberately
                    // default-first, which is what the prose above it reads against.
                    allowed: ["completed", "response", "request"]
                ),
                "limit": .integer("Stop waiting once this many flows have matched (default 1)."),
            ]),
            handler: { ex, args in try await ex.handleWaitForFlow(args) }
        ),
        MCPTool(
            name: "get_stats",
            description: """
            Aggregate the capture instead of reading it: per-bucket flow counts, error rates, and \
            TTFB / receive / duration percentiles, plus the slowest exchanges by id. Answers \
            "which endpoint is slow", "what share of calls to this host fail", "which app is \
            chatty" in one call — and `ttfbMS` vs `receiveMS` answers *why* it is slow: TTFB is \
            server think-time, receive is payload transfer, `duration` is the whole exchange. \
            Don't pull summaries and do the arithmetic yourself; a percentile over one page of \
            summaries isn't a percentile.

            Takes the same filters as `get_recent_flows` (`since_seconds` + `host` scopes it), \
            aggregates every retained flow that matches — memory and the durable store both — and \
            reports `flowsConsidered` as the sample size behind the numbers, with `flowsRetained` \
            as the denominator it came out of. `historyScanTruncated: true` (present only when it \
            happened) means the history walk stopped at its row budget, so the numbers are over a \
            partial sample: narrow with `host` / `since_seconds` and ask again rather than \
            reporting them as the whole picture. `sizeUnknownFlows` on a bucket means its byte \
            totals are a floor: those flows' bodies were evicted from memory, so their size is no \
            longer known.
            """,
            inputSchema: Self.flowFilterSchema.adding([
                "group_by": .string(
                    """
                    What to bucket by (default host). `endpoint` = method + path with the \
                    query dropped and id-shaped segments collapsed to `{id}`, so \
                    `/orders/1` and `/orders/2` are one endpoint. `none` = a single bucket.
                    """,
                    allowed: FlowGrouping.allCases.map(\.rawValue)
                ),
                "limit": .integer("Max buckets, biggest first (default 10). The rest are counted in `bucketsOmitted`."),
                "slowest": .integer("How many slowest-by-TTFB exchanges to name, with ids to follow up on (default 3)."),
            ]),
            handler: { ex, args in try await ex.handleGetStats(args) }
        ),
        MCPTool(
            name: "get_flow_detail",
            description: """
                Get full request and response detail for one flow by id, including headers and body. \
                Bodies are bounded: a body longer than `max_bytes` comes back as {truncated, preview, \
                bytes, offset, nextOffset} — page through it by passing `body_offset: nextOffset`. A \
                body that isn't UTF-8 text comes back as {binary, bytes} rather than an empty string.

                `request.httpVersion` and `response.httpVersion` are two different facts and \
                routinely disagree: the first is what the client negotiated with Loom, the second is \
                Loom's own hop to the origin, which is always HTTP/1.1. An h2 client showing \
                `"HTTP/2"` in and `"HTTP/1.1"` out is normal, not a fault.

                `transport` describes the connection: `remoteAddress` (the origin's IP:port — what \
                DNS actually resolved to), `connectionReused` (false means this exchange paid a TCP \
                connect plus a TLS handshake, which is usually the explanation for a TTFB that looks \
                anomalous next to its neighbours), `clientTLSVersion` / `upstreamTLS` (two separate \
                handshakes, including the origin's certificate issuer and expiry and any mutual-TLS \
                identity Loom presented), and `responseContentEncoding` / `responseEncodedBodyBytes` \
                (the compressed size that crossed the wire — the body itself is reported decompressed, \
                so this is the only reading of what the response cost in bandwidth).

                Every one of those is **omitted when unmeasured, which is not the same as "no"**: an \
                absent `transport` means the exchange never reached a socket (mocked, blocked, or \
                still pending), and an absent `upstreamTLS` does not mean the hop was plaintext.
                """,
            inputSchema: .object(
                [
                    "id": .string("Flow UUID."),
                    "max_bytes": .integer(
                        "Max body bytes to return per side (default \(Self.defaultBodyBytes)). Larger bodies are truncated with a `nextOffset` to page from."
                    ),
                    "body_offset": .integer(
                        "Byte offset into each body, for paging through a large one (default 0)."
                    ),
                    "ws_limit": .integer(
                        "Max WebSocket frames to return, most recent last (default \(Self.defaultWebSocketMessages))."
                    ),
                ],
                required: ["id"]
            ),
            handler: { ex, args in try await ex.handleGetFlowDetail(args) }
        ),
        MCPTool(
            name: "set_recording",
            description: """
            Pause or resume recording captured traffic. Paused, the proxy keeps forwarding \
            (and MITM-decrypting) normally — nothing new is stored, while flows already in \
            flight still complete. Use it to stop unrelated background traffic from burying \
            what you are about to trigger. The human sees it: the panel's capture dot goes \
            yellow and the window's button offers Record again, so a pause you leave behind \
            reads as paused rather than as a broken proxy. Resume when you are done. \
            `get_proxy_status.isRecording` is the current value. This is a write action.
            """,
            inputSchema: .object(
                ["recording": .boolean("true = record, false = pause.")],
                required: ["recording"]
            ),
            isWrite: true,
            handler: { ex, args in try await ex.handleSetRecording(args) }
        ),
        MCPTool(
            name: "clear_flows",
            description: """
            Discard every captured flow, in memory and on disk. Destructive and NOT undoable — \
            the human's window empties too. The point is isolation: clear, trigger the thing \
            you are debugging, then get_recent_flows sees only that. Prefer \
            `get_recent_flows` with `since_seconds` when you don't actually need to destroy \
            the existing capture. This is a write action.
            """,
            inputSchema: .object(),
            isWrite: true,
            handler: { ex, args in try await ex.handleClearFlows(args) }
        ),
        MCPTool(
            name: "get_audit_log",
            description: "List recent write actions taken through Loom (replay, rules, breakpoints, ssl-scope), newest first, each with the tool name, arguments, outcome and timestamp. Read tools are never logged. Use this to review what write actions have been taken this or a prior session.",
            inputSchema: .object(["limit": .integer("Max entries to return (default 50).")]),
            handler: { ex, args in try await ex.handleGetAuditLog(args) }
        ),
        MCPTool(
            name: "replay_flow",
            description: """
            Re-send a captured flow with optional overrides (method, url, headers, body) and \
            return the new flow. `count` re-sends it several times in one call — the way to \
            answer "is this failure intermittent?" or "does it fail under a few in parallel?" \
            without one tool call per attempt. Every attempt is captured as its own flow \
            (linked by `replayedFrom`) and obeys armed rules and breakpoints, exactly like live \
            traffic. This is a write action.

            With `count: 1` (the default) the reply is the new flow. With `count > 1` it is a \
            batch summary: `{requested, succeeded, failed, statusClasses, ttfbMS, durationMS, \
            replays: [{id, status, ttfbMS}], errors}` — failures are reported, not thrown, \
            because "3 of 20 failed" is the answer you were after.
            """,
            inputSchema: .object(
                [
                    "id": .string("Flow UUID to replay."),
                    "count": .integer(
                        "How many times to re-send it (default 1, max \(Self.maxReplayCount)). These are real requests to the real upstream."
                    ),
                    "concurrency": .integer(
                        "How many of those to keep in flight at once (default 1 = one after another, max \(Self.maxReplayConcurrency))."
                    ),
                    "method": .string(),
                    "url": .string(),
                    "set_headers": .freeformObject("Header name/value pairs to add or overwrite."),
                    "remove_headers": .array(of: .string(), "Header names to remove."),
                    "body": .string("Replacement request body (UTF-8). Sent verbatim; if it was meant to be JSON and doesn't parse, the reply carries a `warnings` entry."),
                    "clear_body": .boolean("Send an empty request body (ignored if `body` is set)."),
                ],
                required: ["id"]
            ),
            isWrite: true,
            handler: { ex, args in try await ex.handleReplayFlow(args) }
        ),
        MCPTool(
            name: "diff_flows",
            description: """
            Diff two captured flows and report exactly what differs: request method/url, \
            request+response headers (added/removed/changed), status code, and a line-level body \
            diff for text payloads. Pass `base` alone to diff a replayed flow against the flow it \
            was replayed from. This closes the capture → modify → replay → diff loop.

            Read `identical` together with `captureTruncated`. When the latter is present, a body \
            here is a capture-capped prefix and the bytes past the cap were never compared, so \
            `identical: true` means "identical as far as Loom recorded" — the body block then \
            carries `baseBytesOnWire`/`comparedBytesOnWire` (the real sizes) and, when the \
            prefixes matched, `tailNotCompared`. Two capped bodies with different wire sizes are \
            definitely different even though no line diff is possible.

            A body is not line-diffed when it is binary (`binary`) or too big — `lineDiffSkipped` \
            says which limit it hit: total lines, total bytes, or a single line too long, the last \
            being the ordinary minified-JSON payload. Timing is deliberately not diffed (two runs \
            never share it, so it would make every diff differ); an absent body equals an empty \
            one. For two WebSocket flows a `webSocket` block reports frame counts and \
            `firstDifferingMessage` rather than a whole-log diff.
            """,
            inputSchema: .object(
                [
                    "base": .string("""
                        Baseline flow UUID. If `compared` is omitted, pass the **replayed** \
                        flow's id: it is diffed against its own original (`replayedFrom`), and \
                        the reply reports that original as `baseId` and the replay as \
                        `comparedId` — so the id you passed comes back under the other name. \
                        That is deliberate: the diff always reads original → changed, whichever \
                        end you had at hand.
                        """),
                    "compared": .string("The changed flow UUID to compare against `base`. Optional when `base` is a replay."),
                ],
                required: ["base"]
            ),
            handler: { ex, args in try await ex.handleDiffFlows(args) }
        ),
        MCPTool(
            name: "arm_breakpoint",
            description: "Arm a breakpoint: matching traffic is HELD mid-flight so you can inspect and edit it before it continues. Match by URL pattern (+ optional methods/host/query), same as a rule. Pause the request (before it's forwarded upstream), the response (before it reaches the client), or both. Held exchanges surface in list_pending; release them with resume. This is a write action.",
            inputSchema: .object(
                [
                    "match": Self.matchSchema,
                    "on_request": .boolean("Pause the request before forwarding upstream (default true)."),
                    "on_response": .boolean("Pause the response before it reaches the client (default false)."),
                    "comment": .string("Optional note on why the breakpoint exists."),
                ],
                required: ["match"]
            ),
            isWrite: true,
            handler: { ex, args in try await ex.handleArmBreakpoint(args) }
        ),
        MCPTool(
            name: "disarm_breakpoint",
            description: "Remove an armed breakpoint by id. Exchanges it is already holding still need a resume. This is a write action.",
            inputSchema: .object(
                ["id": .string("Breakpoint UUID (from arm_breakpoint / list_pending).")],
                required: ["id"]
            ),
            isWrite: true,
            handler: { ex, args in try await ex.handleDisarmBreakpoint(args) }
        ),
        MCPTool(
            name: "list_pending",
            description: "List currently armed breakpoints and every exchange held right now awaiting a resume decision. Each pending item carries its id (pass to resume), phase (request/response), full request, and — for a response pause — the response the client would receive. Returns immediately with whatever is held; to wait for the next hold instead of polling, use wait_for_pending.",
            inputSchema: .object(),
            handler: { ex, args in try await ex.handleListPending(args) }
        ),
        MCPTool(
            name: "wait_for_pending",
            description: """
            Block until a breakpoint holds an exchange, then return it — the second half of \
            "arm the breakpoint, trigger the app, edit the request in flight". Anything already \
            held is returned immediately, so the call can't miss a hold that landed first.

            Returns `{pending: [...], timedOut, waitedMS}` with the same item shape as \
            `list_pending`; feed an item's `id` to `resume`. Remember the exchange is holding a \
            real client connection while you think, and an unattended hold auto-proceeds \
            unchanged when the engine's hold timeout expires — so decide, then resume.
            """,
            inputSchema: .object([
                "max_seconds": .number(
                    "How long to wait before giving up (default \(Self.defaultWaitSeconds), max \(Self.maxWaitSeconds)). Timing out is a normal result: `timedOut: true`, empty `pending`."
                ),
                "breakpoint_id": .string("Only wait for holds from this armed breakpoint (from arm_breakpoint)."),
                "limit": .integer("Stop waiting once this many exchanges are held (default 1)."),
            ]),
            handler: { ex, args in try await ex.handleWaitForPending(args) }
        ),
        MCPTool(
            name: "resume",
            description: "Release a held exchange by its pending id. Continue it (optionally editing method/url/status/headers/body first) or `abort` to fail it with a 502. Request-phase edits honor method/url; response-phase edits honor status_code; both honor header + body edits. This is a write action.",
            inputSchema: .object(
                [
                    // One name, deliberately — an `id` alias was accepted here for four
                    // releases (undeclared, so `validateArguments` refused it anyway) on
                    // the reasoning that an item from list_pending should copy across
                    // verbatim. That is the argument *against* it: list_pending returns
                    // two arrays whose entries both render an `id`, the armed breakpoint's
                    // and the held exchange's, both UUIDs. An alias accepts the wrong one
                    // and the engine answers "no such hold", which reads as a hold that
                    // already resolved rather than as the wrong kind of id. Rejected at
                    // the choke point, the same slip names itself and suggests the fix.
                    "pending_id": .string(
                        "The held exchange's id — the `id` of an entry in list_pending / wait_for_pending's `pending` array, NOT the `id` of an `armed` breakpoint (that one is `breakpointId` on the held entry)."
                    ),
                    "abort": .boolean("Fail the exchange with a 502 instead of continuing (default false)."),
                    "method": .string("Request-phase only: replace the HTTP method."),
                    "url": .string("Request-phase only: replace the full URL."),
                    "status_code": .integer("Response-phase only: replace the status code."),
                    "set_headers": .freeformObject("Header name/value pairs to add or overwrite."),
                    "remove_headers": .array(of: .string(), "Header names to remove."),
                    "body": .string("Replacement body (UTF-8). Sent verbatim; if it was meant to be JSON and doesn't parse, the reply carries a `warnings` entry."),
                    "clear_body": .boolean("Send an empty body (ignored if `body` is set)."),
                ],
                required: ["pending_id"]
            ),
            isWrite: true,
            handler: { ex, args in try await ex.handleResume(args) }
        ),
        MCPTool(
            name: "get_certificate_status",
            description: "Get the HTTPS-interception root CA status: whether it exists, whether it's trusted on this machine, its SHA-256 fingerprint, expiry, and exported PEM path.",
            inputSchema: .object(),
            handler: { ex, args in try await ex.handleGetCertificateStatus(args) }
        ),
        MCPTool(
            name: "export_ca_certificate",
            description: "Write Loom's root CA certificate (PEM) to disk so it can be trusted, and return the file path. This is a write action.",
            inputSchema: .object(),
            isWrite: true,
            handler: { ex, args in try await ex.handleExportCACertificate(args) }
        ),
        MCPTool(
            name: "get_ssl_scope",
            description: """
            Get the SSL-proxying scope: whether interception is enabled and the include/exclude \
            host globs. Hosts matching an include glob (and no exclude glob) are MITM-decrypted; \
            everything else is blind-tunneled. The default is `include: ["*"]`, so a host is \
            usually missing because someone put it in `exclude` — a client that carries its own \
            certificate store (a JVM, Python, Go) or a pinned host has to be carved out or it \
            fails its handshake.

            `tunneledHosts` is how you tell a carve-out from an idle client: one entry per origin \
            Loom relayed without reading, newest first, with `connections`, `lastSeen` and a \
            `reason`. A relayed connection records NO flow at all — not an empty one — so this is \
            the only surface holding the fact. `excluded`/`notInScope`/`interceptionDisabled` mean \
            `intercept_host` would fix it (`interceptable: true`); `notTLSOrHTTP` (h2c, SSH, \
            SMTP, a server-first protocol), `noCertificateAuthority` and `leafMintFailed` mean no \
            scope change will. Two reasons mean the traffic did not merely go unread — the \
            request never happened and the operator's page is broken: `clientHandshakeFailed` \
            (the client refused Loom's leaf and hung up before sending anything; fix is an \
            `exclude` entry or trusting Loom's CA in that client) and `protocolError` (Loom's \
            HTTP/2 codec could not read the connection and closed it; `detail` carries the \
            codec's own error). Both carry `detail`, and both clear themselves once a client \
            completes a handshake against Loom's leaf on that host. Read this before concluding \
            a client made no requests. \
            `tunneledHostsEvicted` counts entries dropped past the 256-host cap.
            """,
            inputSchema: .object(),
            handler: { ex, args in try await ex.handleGetSSLScope(args) }
        ),
        MCPTool(
            name: "intercept_host",
            description: """
            Start decrypting one host: add it to the SSL scope's include list, turning \
            interception on if it was off and dropping an exact exclude for it. The one-step, \
            atomic version of reading `get_ssl_scope` and writing `set_ssl_scope` back, so it \
            can't lose a concurrent edit from the human at the console. Usually called on a host \
            someone carved into `exclude` that you now need to read.

            Only affects connections made AFTER the call; an exchange already relayed is gone, so \
            re-run the client. The reply says what it took: `effective` (false when a wildcard \
            `exclude` still shadows the host — `shadowedByExclude` names it, and only whoever \
            wrote that glob should narrow it), `alreadyIncluded`, `enabledInterception`, \
            `removedExcludes`, plus the resulting scope. Decrypting also needs Loom's root CA \
            trusted by the client — see get_certificate_status. This is a write action.
            """,
            inputSchema: .object(
                [
                    "host": .string(
                        "Exact hostname, as it appears in get_ssl_scope's tunneledHosts (e.g. \"api.example.com\"). Not a glob — use set_ssl_scope for those."
                    ),
                ],
                required: ["host"]
            ),
            isWrite: true,
            handler: { ex, args in try await ex.handleInterceptHost(args) }
        ),
        MCPTool(
            name: "set_ssl_scope",
            description: "Set the SSL-proxying scope. Enables/disables HTTPS interception and replaces the include/exclude host globs (e.g. \"*.example.com\"). exclude doubles as the pinned/pass-through list. This is a write action.",
            inputSchema: .object([
                "enabled": .boolean("Master switch for HTTPS interception."),
                "include": .array(
                    of: .string(), "Host globs to decrypt, e.g. [\"*.example.com\", \"api.test\"]."
                ),
                "exclude": .array(
                    of: .string(), "Host globs to pass through untouched (pinned hosts)."
                ),
            ]),
            isWrite: true,
            handler: { ex, args in try await ex.handleSetSSLScope(args) }
        ),
        MCPTool(
            name: "list_client_certificates",
            description: """
            List the mutual-TLS client identities Loom presents to origins that ask for one: \
            host pattern, label, enabled state, the leaf's subject and expiry, and `problem` \
            when the stored bundle can't be read. Never returns the key or the passphrase. \
            Check this when an https:// host fails its handshake for no visible reason — an \
            expired or unreadable identity fails exactly like a missing one.
            """,
            inputSchema: .object(),
            handler: { ex, args in try await ex.handleListClientCertificates(args) }
        ),
        MCPTool(
            name: "set_client_certificate",
            description: """
            Add or replace a mutual-TLS client identity (pass the same `id` to replace). Some \
            origins — internal and partner APIs especially — demand a client certificate during \
            the TLS handshake; without one Loom's upstream leg fails to connect at all, so the \
            exchange can't be captured. The bundle is validated immediately, so a wrong \
            passphrase is reported here rather than as a request failure later.

            Scope it with `host_pattern` (glob, same semantics as the SSL scope). Presenting a \
            certificate identifies its holder to whoever asked, so `*` is almost never right. \
            This is a write action; the bundle and passphrase are redacted in the audit trail.
            """,
            inputSchema: .object(
                [
                    "host_pattern": .string(
                        "Hosts to present this identity to, e.g. \"api.corp.example\" or \"*.corp.example\"."
                    ),
                    "pkcs12_base64": .string(
                        "Base64 of the PKCS#12 (.p12/.pfx) bundle holding the leaf, chain and private key."
                    ),
                    "passphrase": .string(
                        "Passphrase for the bundle. Omit for an unprotected export."
                    ),
                    "label": .string("Name for the operator's list (defaults to host_pattern)."),
                    "enabled": .boolean("Present this identity (default true)."),
                    "id": .string("Replace the identity with this id instead of adding one."),
                ],
                required: ["host_pattern", "pkcs12_base64"]
            ),
            isWrite: true,
            handler: { ex, args in try await ex.handleSetClientCertificate(args) }
        ),
        MCPTool(
            name: "delete_client_certificate",
            description: "Remove a mutual-TLS client identity by id (from list_client_certificates). Hosts it covered will go back to failing the handshake if they require one. This is a write action.",
            inputSchema: .object(
                ["id": .string("The identity's id.")],
                required: ["id"]
            ),
            isWrite: true,
            handler: { ex, args in try await ex.handleDeleteClientCertificate(args) }
        ),
        MCPTool(
            name: "export_har",
            description: """
            Export captured flows to a HAR 1.2 file (readable by Chrome DevTools / Charles / \
            Proxyman, and by Loom's own import_har) and return the path. Optionally filter by \
            host and cap the count.

            Set `redact: true` when the file is going anywhere — a ticket, a chat, a CI artifact. \
            It replaces credential-bearing header values and query parameters with `<redacted>` \
            (the header stays, so a reader can tell a scrubbed token from an absent one), but does \
            NOT touch bodies or WebSocket frames — a password in a login POST body survives it. \
            Add `redact_bodies: true` for those, which blanks them while keeping their sizes. \
            Redaction is off by default because a debugging export usually needs the token; that \
            is often the bug. This is a write action (writes a file).
            """,
            inputSchema: .object([
                "host": .string("Only include flows whose host contains this string."),
                "limit": .integer("Max flows to include (default 1000, newest first)."),
                "filename": .string("Output file name (basename only; a .har suffix is added if missing). Written under ~/Library/Application Support/com.loom/exports/. Defaults to loom-export.har."),
                "redact": .boolean(
                    "Scrub credentials: Authorization/Cookie/API-key headers and token-ish query parameters become `<redacted>`."
                ),
                "redact_headers": .array(
                    of: .string(),
                    "Extra header names to scrub, on top of the built-in set (implies redact)."
                ),
                "redact_bodies": .boolean(
                    "Drop request/response bodies and WebSocket frame payloads, keeping their sizes (implies redact). Use when you can't audit every payload — which is most of the time if the file is leaving the machine."
                ),
            ]),
            isWrite: true,
            handler: { ex, args in try await ex.handleExportHAR(args) }
        ),
        MCPTool(
            name: "import_har",
            description: """
            Load a HAR 1.2 file into the capture as flows, so exchanges recorded elsewhere — a \
            colleague's DevTools export, a CI artifact, a bug report, an earlier Loom export — \
            can be read, diffed and **replayed** with the same tools as live traffic.

            Imported flows are labelled `importedFrom` (they sit alongside captured traffic, so \
            they must not be mistaken for it) and get fresh ids, returned in `ids`. An entry the \
            parser can't use is skipped and reported in `skipped`/`skippedReasons` — never \
            silently, so "12 of 15" can't read as "all of them". This is a write action (it \
            changes what the capture contains, and the human's window shows them too).
            """,
            inputSchema: .object(
                [
                    "path": .string("Path to the .har file (~ is expanded)."),
                    "label": .string("What to record as `importedFrom` (defaults to the file name)."),
                ],
                required: ["path"]
            ),
            isWrite: true,
            handler: { ex, args in try await ex.handleImportHAR(args) }
        ),
        MCPTool(
            name: "list_rules",
            description: "List traffic rules and the master rules switch. Without arguments, returns all rules with mock/rewrite bodies truncated. Pass `id` to return that single rule with full (untruncated) bodies.",
            inputSchema: .object(
                ["id": .string("Optional rule UUID — return just this rule, with full bodies.")]
            ),
            handler: { ex, args in try await ex.handleListRules(args) }
        ),
        MCPTool(
            name: "set_rule",
            description: """
            Create or update a traffic rule (upsert): omit `id` to create, pass `id` to update. A \
            rule matches requests by URL pattern (+ optional methods) and acts on them — mock the \
            response, map to another origin or a local file, rewrite request/response headers or \
            bodies, block, or delay. Rules apply to live traffic and replays, in list order.

            On update, provided fields replace the existing ones (match/actions are replaced \
            whole, not merged); toggle a single rule with just {id, enabled}. The reply carries \
            `effective` — whether the rule will actually affect traffic — plus `ineffectiveReason` \
            when it will not, most often the rules master switch being off, which silently \
            neutralises every rule. Check it before reporting that a mock is in place. This is a \
            write action.
            """,
            // No `required`: this is an upsert, so even `name` is only required when
            // creating, which a schema can't express. The dictionary version said so
            // with an explicit `"required": []`, which JSON Schema treats exactly as
            // an absent one — `JSONSchema` emits no key rather than an empty array.
            inputSchema: .object([
                "id": .string("Rule UUID to update. Omit to create a new rule."),
                "name": .string("Short human-readable rule name (shows in flow audit trails). Required when creating."),
                "comment": .string("Optional note on why the rule exists."),
                "group": .string("Optional group label (e.g. one group per scenario); a whole group can be toggled with set_group_enabled. On update, pass \"\" to ungroup."),
                "enabled": .boolean("Default true on create."),
                "match": Self.matchSchema,
                "actions": Self.actionsSchema,
            ]),
            isWrite: true,
            handler: { ex, args in try await ex.handleSetRule(args) }
        ),
        MCPTool(
            name: "delete_rule",
            description: "Delete a traffic rule by id. This is a write action.",
            inputSchema: .object(["id": .string("Rule UUID.")], required: ["id"]),
            isWrite: true,
            handler: { ex, args in try await ex.handleDeleteRule(args) }
        ),
        MCPTool(
            name: "set_rules_enabled",
            description: "Master switch for the rule engine. When off, no rule is applied regardless of per-rule flags. This is a write action.",
            inputSchema: .object(["enabled": .boolean()], required: ["enabled"]),
            isWrite: true,
            handler: { ex, args in try await ex.handleSetRulesEnabled(args) }
        ),
        MCPTool(
            name: "set_group_enabled",
            description: """
            Switch a whole rule group on or off — scenario switching. Non-destructive: it sets the \
            group's own switch and leaves each rule's `enabled` flag alone, so switching a group \
            off and back on restores exactly the rules that were on before. A rule in a \
            switched-off group therefore reads `enabled: true` and still does nothing; `list_rules` \
            reports `disabledGroups` (with `null` for the ungrouped bucket) and `set_rule` says so \
            in `ineffectiveReason`. The reply's `members` counts the group, `active` counts how \
            many of them now apply. This is a write action.
            """,
            inputSchema: .object(
                [
                    "group": .string("Group label as shown in list_rules."),
                    "enabled": .boolean(),
                ],
                required: ["group", "enabled"]
            ),
            isWrite: true,
            handler: { ex, args in try await ex.handleSetGroupEnabled(args) }
        ),
    ]

    /// Shared `match` schema for `set_rule` and `arm_breakpoint` — one match
    /// vocabulary, so a rule and a breakpoint can't come to mean different things by
    /// the same words.
    static let matchSchema: JSONSchema = .object(
        [
            "url_pattern": .string(
                "Matched against the full URL, the way match_style says. Omit match_style and the pattern speaks for itself: a `*` in it means glob, otherwise prefix."
            ),
            "match_style": .string(
                "How url_pattern is compared. prefix: the pattern must be a case-insensitive prefix of the URL, so a pattern with no query string still matches every query string. glob: `*` matches any run of characters and the pattern must cover the whole URL. exact: the URL must equal the pattern. regex: unanchored, case-insensitive. Defaults to glob when the pattern contains `*`, else prefix — pass it explicitly to match a literal `*`. Read back as `matchStyle`.",
                allowed: MatchStyle.allCases.map(\.rawValue)
            ),
            "is_regex": .boolean("Older spelling of match_style: \"regex\". Ignored when match_style is set."),
            "is_exact": .boolean("Older spelling of match_style: \"exact\". Ignored when match_style is set; is_regex wins over it."),
            "host_pattern": .string("Optional host glob (e.g. *.example.com) matched against the URL host; combines with url_pattern."),
            "query": .freeformObject(
                "Optional query predicates, order-independent: each key must be present and equal its value, or \"*\" to require the key with any value. To require a value that is literally `*`, use the explicit form {\"key\": {\"equals\": \"*\"}} — {\"key\": {\"present\": true}} is the long spelling of \"*\". Read back in the same spelling."
            ),
            "source_app": .string(
                "Optional originating-app predicate: bundle id or display name (see list_devices / a flow's sourceApp), case-insensitive. This is how you scope a rule to one client — mock it for the app under test and leave the browser alone. Traffic Loom can't attribute to a local process (a LAN device has no local pid) never matches an app-scoped rule."
            ),
            "device_ip": .string(
                "Optional originating-device predicate: the device's IP as seen by the proxy (see list_devices). Scopes a rule to one phone/machine; unattributed traffic never matches."
            ),
            "methods": .array(
                of: .string(), "HTTP methods to match, e.g. [\"GET\"]. Empty/omitted = all methods."
            ),
        ],
        required: ["url_pattern"],
        description: "What traffic the rule applies to, matched against the original client request."
    )

    /// Shared `actions` schema for `set_rule`.
    static let actionsSchema: JSONSchema = .object(
        [
            "block": .boolean("Refuse the request with 403; the upstream is never contacted."),
            "mock_response": .object(
                [
                    "status_code": .integer("Default 200."),
                    "headers": .freeformObject("Response header name/value pairs."),
                    "body": .string("UTF-8 response body (e.g. a JSON document). Sent verbatim — a malformed payload is allowed on purpose — but if it was meant to be JSON and doesn't parse, the reply carries a `warnings` entry naming the parse error."),
                    "body_base64": .string("Base64-encoded response body for binary payloads (images, protobuf, gzip). Takes precedence over body."),
                    "content_type": .string("Convenience Content-Type, e.g. application/json."),
                ],
                description: "Short-circuit with a synthesized response; the upstream is never contacted."
            ),
            "map_remote": .object(
                [
                    "destination": .string("Origin like http://127.0.0.1:3001 (scheme + host + optional port)."),
                    "exclude": .string("URLs matching this glob/regex are left un-redirected."),
                    "keep_host_header": .boolean("Keep the original Host header instead of following the new origin."),
                ],
                required: ["destination"],
                description: "Re-send the request to a different origin, keeping path + query."
            ),
            "map_local": .object(
                [
                    "path": .string("Absolute file path."),
                    "status_code": .integer("Default 200."),
                    "content_type": .string("Default: guessed from the file extension."),
                ],
                required: ["path"],
                description: "Serve a local file as the response; the upstream is never contacted. It carries no headers of its own beyond content_type — add any others with rewrite_response.set_headers, which runs over whatever the route produced."
            ),
            "rewrite_request": .object(
                [
                    "method": .string(),
                    "url": .string("Replacement request URL, whole (scheme + host + path + query). Unlike map_remote, which swaps the origin and keeps the path, this sets the lot; the Host header follows it."),
                    "set_headers": .freeformObject("Header name/value pairs to add or overwrite."),
                    "remove_headers": .array(of: .string()),
                    "body": .string("Replacement UTF-8 request body. \"\" replaces it with an empty body, which is different from omitting this key (leave the client's body alone). Sent verbatim; if it was meant to be JSON and doesn't parse, the reply carries a `warnings` entry."),
                    "body_file": .string("Absolute path to a file whose contents replace the request body, read at request time so editing the file needs no rule change. Takes precedence over `body`. If it can't be read the client's own body is forwarded and the failure is logged (a request has no response to report it on)."),
                ],
                description: "Mutate the outgoing request before forwarding."
            ),
            "rewrite_response": .object(
                [
                    "status_code": .integer(),
                    "set_headers": .freeformObject("Header name/value pairs to add or overwrite."),
                    "remove_headers": .array(of: .string()),
                    "body": .string("Replacement UTF-8 response body. Sent verbatim; if it was meant to be JSON and doesn't parse, the reply carries a `warnings` entry."),
                ],
                description: "Mutate the response (real or mocked) before it reaches the client."
            ),
            "request_substitutions": Self.substitutionsSchema(
                "Find/replace substitutions on the outgoing request (\"modify request\"). Applied in order."),
            "response_substitutions": Self.substitutionsSchema(
                "Find/replace substitutions on the returned response (\"modify response\"). Applied in order."),
            "delay_ms": .integer("Hold the response back this many milliseconds (crude throttle)."),
        ],
        description: "What to do with matching traffic. Set any combination. block beats mock_response beats map_local when several short-circuits match; request rewrites compose in rule order."
    )

    static func substitutionsSchema(_ description: String) -> JSONSchema {
        .array(
            of: .object(
                [
                    "field": .string(
                        "Which part to substitute in (url is request-side only).",
                        allowed: SubstitutionRule.Field.Kind.allCases.map(\.rawValue)
                    ),
                    "header_name": .string(
                        "With field \"header\": the one header to substitute in, case-insensitive (e.g. Authorization). Omit to run over every header's value, which is blunt — it also hits any other header containing the same text. Rejected with any other field."
                    ),
                    "match": .string("Text or regex to find."),
                    "replacement": .string("Replacement text (regex $1 backrefs allowed)."),
                    "is_regex": .boolean("Treat match as a regular expression (default false)."),
                    "case_sensitive": .boolean("Case-sensitive match (default false)."),
                ],
                required: ["field", "match"]
            ),
            description
        )
    }
}
