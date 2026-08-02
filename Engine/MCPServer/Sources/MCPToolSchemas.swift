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
struct MCPTool {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    /// Touches real traffic, so `MCPToolExecutor.call` records it in the audit trail.
    let isWrite: Bool
    let handler: (MCPToolExecutor, [String: Any]) async throws -> String

    init(
        name: String,
        description: String,
        inputSchema: [String: Any],
        isWrite: Bool = false,
        handler: @escaping (MCPToolExecutor, [String: Any]) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.isWrite = isWrite
        self.handler = handler
    }

    /// The `tools/list` JSON for this tool.
    var definition: [String: Any] {
        ["name": name, "description": description, "inputSchema": inputSchema]
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
    /// The flow-filter arguments, shared verbatim by `get_recent_flows` and
    /// `wait_for_flow` — one filter vocabulary, parsed by one `flowQuery(from:)`, so
    /// the two can't drift into subtly different notions of "matching".
    static let flowFilterProperties: [String: Any] = [
        "host": ["type": "string", "description": "Host, exact or glob: `api.example.com`, `*.example.com`."],
        "method": [
            "description": "HTTP method(s) to include, case-insensitive. A string or an array of strings.",
            "oneOf": [
                ["type": "string"],
                ["type": "array", "items": ["type": "string"]],
            ],
        ],
        "url_contains": ["type": "string", "description": "Case-insensitive substring of the full URL (path, query, …)."],
        "header_contains": [
            "type": "string",
            "description": """
            Case-insensitive substring of a header. Plain text matches a header name or \
            value (`authorization`, `Bearer ey`); with a colon it means `name: value` and \
            both halves must hit the same header (`x-env: staging`, or `set-cookie:` for \
            "has this header at all"). Searches both sides unless `header_in` narrows it.
            """,
        ],
        "header_in": [
            "type": "string",
            "enum": ["any", "request", "response"],
            "description": """
            Which side `header_contains` searches; default `any`. Most header questions \
            have a side — "who sent this auth header" is about requests, "who set this \
            cookie" is about responses — and searching both buries the answer.
            """,
        ],
        "body_contains": [
            "type": "string",
            "description": """
            Case-insensitive substring of a captured body — the "which exchange carried \
            this id/token/error string" filter. Matched over raw bytes, so non-UTF-8 \
            payloads are searched too. Searches both sides unless `body_in` narrows it. \
            Combine with `host` / `url_contains` / `since_seconds` to keep the scan \
            narrow, and note a flow with `captureTruncated: true` holds only a body \
            prefix, so a miss on one of those isn't proof.
            """,
        ],
        "body_in": [
            "type": "string",
            "enum": ["any", "request", "response"],
            "description": """
            Which side `body_contains` searches; default `any`. Use `request` for the \
            usual question — "which request carried this order id" — because a list \
            endpoint's *response* typically contains every id in the system, so searching \
            both returns a page of noise around the one hit you wanted.
            """,
        ],
        "status": [
            "description": "Status code: an exact number (500) or a class as a string (\"5xx\", \"4xx\").",
            "oneOf": [
                ["type": "integer"],
                ["type": "string"],
            ],
        ],
        "status_min": ["type": "integer", "description": "Lowest status code to include (inclusive)."],
        "status_max": ["type": "integer", "description": "Highest status code to include (inclusive)."],
        "only_errors": ["type": "boolean", "description": "Only failures: a transport error or status >= 400 (in-flight flows are excluded)."],
        "since_seconds": ["type": "number", "description": "Only flows started within the last N seconds — the usual way to isolate \"what I just triggered\"."],
        "since": ["type": "string", "description": "Only flows started at/after this ISO-8601 timestamp (alternative to `since_seconds`)."],
        "device_ip": ["type": "string", "description": "Only traffic from this device IP (see list_devices)."],
        "source_app": ["type": "string", "description": "Only traffic from this local app, by bundle id or display name."],
    ]

    /// JSON metadata advertised by `tools/list`, derived from the one table.
    var toolDefinitions: [[String: Any]] { Self.tools.map(\.definition) }

    /// The tool surface: one value per tool, carrying everything that used to be
    /// aligned by hand across four places — the advertised definition, the
    /// handler, and whether the call is a write action (and so audited).
    static let tools: [MCPTool] = [
        MCPTool(
            name: "get_version",
            description: "Get the Loom app version and MCP protocol version.",
            inputSchema: ["type": "object", "properties": [:] as [String: Any]],
            handler: { ex, args in try await ex.handleGetVersion(args) }
        ),
        MCPTool(
            name: "get_proxy_status",
            description: """
            Get the current proxy status: running state, listen address, captured flow count, \
            whether recording is paused, and whether this Mac's own traffic is actually routed \
            through Loom (`systemProxy`). Check this first when a capture comes back empty — \
            "nothing happened" and "nothing was pointed at the proxy" look identical otherwise. \
            `systemProxy` is one of: `"on"` (routed through Loom), `"off"` (no system proxy set), \
            `"other"` (another proxy app — Charles, Proxyman, whistle — owns the setting; \
            `systemProxyPointsAt` gives its host:port), or `"unavailable"` (this build can't \
            inspect it, which is not the same as off). On `"other"`, say so rather than calling \
            `set_system_proxy`: taking the setting works, but Loom does not put the other app's \
            configuration back, so that is the human's call to make.

            When a capture is empty and routing looks fine, check `refusedConnections` / \
            `recentRefusals` (present only when there are any): a client that reached Loom and \
            was turned away — a SOCKS4 client, an HTTP request sent to the SOCKS port, an \
            unsupported command — looks exactly like a client that never ran, and this is the \
            difference.
            """,
            inputSchema: ["type": "object", "properties": [:] as [String: Any]],
            handler: { ex, args in try await ex.handleGetProxyStatus(args) }
        ),
        MCPTool(
            name: "set_system_proxy",
            description: """
            Route this Mac's HTTP/HTTPS traffic through Loom, or stop routing it. This is what \
            makes local apps and browsers appear in the capture without configuring each one, \
            and it is the fix when `get_proxy_status` shows nothing is routed here.

            Machine-wide and visible to the human: it edits the active network service's proxy \
            settings, may ask for an admin password, and also installs a pf rule blocking QUIC \
            (UDP 443) so browsers fall back to TCP where a proxy can see them — browsers \
            default to HTTP/3, which no TCP proxy can intercept. Turn it off when you're done; \
            Loom also turns it off on quit. Disabling never hands the setting back to whoever \
            held it before — if `get_proxy_status` reported `"other"`, say so and let the human \
            re-enable that app themselves. Traffic from a phone or another device does NOT need \
            this (point that device at the proxy instead). This is a write action.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "enabled": ["type": "boolean", "description": "true = route this Mac through Loom, false = turn the system proxy off (NOT restore a previous owner's settings)."],
                ],
                "required": ["enabled"],
            ],
            isWrite: true,
            handler: { ex, args in try await ex.handleSetSystemProxy(args) }
        ),
        MCPTool(
            name: "list_devices",
            description: "List devices that have sent traffic through the proxy — this Mac plus any LAN devices (e.g. phones), each with detected platform/client (from User-Agent), flow count, and last-seen time.",
            inputSchema: ["type": "object", "properties": [:] as [String: Any]],
            handler: { ex, args in try await ex.handleListDevices(args) }
        ),
        MCPTool(
            name: "get_recent_flows",
            description: """
            List captured HTTP flows, newest first, with method, url, status, timing and startedAt. \
            Filters (all optional, ANDed) are applied across every retained flow BEFORE `limit`, \
            so a match that isn't among the newest exchanges is still found — prefer filtering here \
            over pulling a big list and scanning it yourself. `captureTruncated: true` on a summary \
            means the recorded body/frame log is only a prefix of what actually flowed.
            """,
            inputSchema: [
                "type": "object",
                "properties": Self.flowFilterProperties.merging([
                    "limit": ["type": "integer", "description": "Max flows to return after filtering (default 20)."],
                ]) { current, _ in current },
            ],
            handler: { ex, args in try await ex.handleGetRecentFlows(args) }
        ),
        MCPTool(
            name: "wait_for_flow",
            description: """
            Block until a flow matching the filters is captured, then return it — the \
            "trigger the action, then see the request it made" tool. Takes the same filters as \
            `get_recent_flows`, so you never poll it in a loop.

            It is a query over the retained capture *and* a wait, in that order: flows already \
            stored are checked first, so a request you triggered a moment before calling is \
            returned immediately rather than waited for. Nothing is lost if the call times out \
            at any layer — the flow stays in the store, and calling again with `since` set to \
            the previous reply's `windowFrom` finds it with no gap.

            Returns `{matched: [...summaries], timedOut, waitedMS, windowFrom}`. The default \
            window is the last \(Int(Self.defaultWaitLookback)) seconds (not "from now on", so \
            the trigger-then-call sequence can't race); pass `since_seconds` or `since` to widen \
            or pin it.
            """,
            inputSchema: [
                "type": "object",
                "properties": Self.flowFilterProperties.merging([
                    "max_seconds": [
                        "type": "number",
                        "description": """
                        How long to wait before giving up (default \(Self.defaultWaitSeconds), \
                        max \(Self.maxWaitSeconds)). A timeout is a normal result, not an error: \
                        `timedOut: true` with an empty `matched`.
                        """,
                    ],
                    "until": [
                        "type": "string",
                        "enum": ["completed", "response", "request"],
                        "description": """
                        How much of the exchange to wait for. `completed` (default) = it finished \
                        or failed, so status, timing and both bodies are final. `response` = the \
                        status line is known but the body may still be streaming — use this for a \
                        WebSocket (the 101 upgrade), which otherwise never completes while the \
                        socket is open, or for a long download. `request` = return the moment the \
                        request is seen, before any response exists.
                        """,
                    ],
                    "limit": ["type": "integer", "description": "Stop waiting once this many flows have matched (default 1)."],
                ]) { current, _ in current },
            ],
            handler: { ex, args in try await ex.handleWaitForFlow(args) }
        ),
        MCPTool(
            name: "get_stats",
            description: """
            Aggregate the capture instead of reading it: per-bucket flow counts, error rates, \
            and TTFB / receive / duration percentiles, plus the slowest exchanges by id. \
            Answers "which endpoint is slow", "what share of calls to this host fail", "which \
            app is chatty" in one call — and `ttfbMS` vs `receiveMS` answers *why* it is slow: \
            high TTFB is server think-time, high receive is payload transfer — don't pull flow summaries and do the arithmetic yourself, and note \
            that a percentile over one page of summaries isn't a percentile.

            Takes the same filters as `get_recent_flows` (so `since_seconds` + `host` scopes it \
            to what you care about). Aggregates every retained flow that matches, and reports \
            `flowsConsidered` so you can see the sample size behind the numbers. TTFB is server \
            think-time; `duration` is the whole exchange. `sizeUnknownFlows` on a bucket means \
            its byte totals are a floor: those flows' bodies have been evicted from memory, so \
            their size is no longer known.
            """,
            inputSchema: [
                "type": "object",
                "properties": Self.flowFilterProperties.merging([
                    "group_by": [
                        "type": "string",
                        "enum": FlowGrouping.allCases.map(\.rawValue),
                        "description": """
                        What to bucket by (default host). `endpoint` = method + path with the \
                        query dropped and id-shaped segments collapsed to `{id}`, so \
                        `/orders/1` and `/orders/2` are one endpoint. `none` = a single bucket.
                        """,
                    ],
                    "limit": ["type": "integer", "description": "Max buckets, biggest first (default 10). The rest are counted in `bucketsOmitted`."],
                    "slowest": ["type": "integer", "description": "How many slowest-by-TTFB exchanges to name, with ids to follow up on (default 3)."],
                ]) { current, _ in current },
            ],
            handler: { ex, args in try await ex.handleGetStats(args) }
        ),
        MCPTool(
            name: "get_flow_detail",
            description: "Get full request and response detail for one flow by id, including headers and body. Bodies are bounded: a body longer than `max_bytes` comes back as {truncated, preview, bytes, offset, nextOffset} — page through it by passing `body_offset: nextOffset`. A body that isn't UTF-8 text comes back as {binary, bytes} rather than an empty string.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Flow UUID."],
                    "max_bytes": [
                        "type": "integer",
                        "description": "Max body bytes to return per side (default \(Self.defaultBodyBytes)). Larger bodies are truncated with a `nextOffset` to page from.",
                    ],
                    "body_offset": [
                        "type": "integer",
                        "description": "Byte offset into each body, for paging through a large one (default 0).",
                    ],
                    "ws_limit": [
                        "type": "integer",
                        "description": "Max WebSocket frames to return, most recent last (default \(Self.defaultWebSocketMessages)).",
                    ],
                ],
                "required": ["id"],
            ],
            handler: { ex, args in try await ex.handleGetFlowDetail(args) }
        ),
        MCPTool(
            name: "set_recording",
            description: """
            Pause or resume recording captured traffic. Paused, the proxy keeps forwarding \
            (and MITM-decrypting) normally — nothing new is stored, while flows already in \
            flight still complete. Use it to stop unrelated background traffic from burying \
            what you are about to trigger. This is a write action.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "recording": ["type": "boolean", "description": "true = record, false = pause."],
                ],
                "required": ["recording"],
            ],
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
            inputSchema: ["type": "object", "properties": [:] as [String: Any]],
            isWrite: true,
            handler: { ex, args in try await ex.handleClearFlows(args) }
        ),
        MCPTool(
            name: "get_audit_log",
            description: "List recent write actions taken through Loom (replay, rules, breakpoints, ssl-scope), newest first, each with the tool name, arguments, outcome and timestamp. Read tools are never logged. Use this to review what write actions have been taken this or a prior session.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "description": "Max entries to return (default 50)."],
                ],
            ],
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
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Flow UUID to replay."],
                    "count": [
                        "type": "integer",
                        "description": "How many times to re-send it (default 1, max \(Self.maxReplayCount)). These are real requests to the real upstream.",
                    ],
                    "concurrency": [
                        "type": "integer",
                        "description": "How many of those to keep in flight at once (default 1 = one after another, max \(Self.maxReplayConcurrency)).",
                    ],
                    "method": ["type": "string"],
                    "url": ["type": "string"],
                    "set_headers": [
                        "type": "object",
                        "description": "Header name/value pairs to add or overwrite.",
                    ],
                    "remove_headers": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Header names to remove.",
                    ],
                    "body": ["type": "string", "description": "Replacement request body (UTF-8)."],
                    "clear_body": ["type": "boolean", "description": "Send an empty request body (ignored if `body` is set)."],
                ],
                "required": ["id"],
            ],
            isWrite: true,
            handler: { ex, args in try await ex.handleReplayFlow(args) }
        ),
        MCPTool(
            name: "diff_flows",
            description: "Diff two captured flows and report exactly what differs: request method/url, request+response headers (added/removed/changed), status code, and a line-level body diff for text payloads. Pass `base` alone to diff a replayed flow against the flow it was replayed from. This closes the capture → modify → replay → diff loop.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "base": [
                        "type": "string",
                        "description": """
                        Baseline flow UUID. If `compared` is omitted, pass the **replayed** \
                        flow's id: it is diffed against its own original (`replayedFrom`), and \
                        the reply reports that original as `baseId` and the replay as \
                        `comparedId` — so the id you passed comes back under the other name. \
                        That is deliberate: the diff always reads original → changed, whichever \
                        end you had at hand.
                        """,
                    ],
                    "compared": ["type": "string", "description": "The changed flow UUID to compare against `base`. Optional when `base` is a replay."],
                ],
                "required": ["base"],
            ],
            handler: { ex, args in try await ex.handleDiffFlows(args) }
        ),
        MCPTool(
            name: "arm_breakpoint",
            description: "Arm a breakpoint: matching traffic is HELD mid-flight so you can inspect and edit it before it continues. Match by URL pattern (+ optional methods/host/query), same as a rule. Pause the request (before it's forwarded upstream), the response (before it reaches the client), or both. Held exchanges surface in list_pending; release them with resume. This is a write action.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "match": Self.matchSchema,
                    "on_request": ["type": "boolean", "description": "Pause the request before forwarding upstream (default true)."],
                    "on_response": ["type": "boolean", "description": "Pause the response before it reaches the client (default false)."],
                    "comment": ["type": "string", "description": "Optional note on why the breakpoint exists."],
                ],
                "required": ["match"],
            ],
            isWrite: true,
            handler: { ex, args in try await ex.handleArmBreakpoint(args) }
        ),
        MCPTool(
            name: "disarm_breakpoint",
            description: "Remove an armed breakpoint by id. Exchanges it is already holding still need a resume. This is a write action.",
            inputSchema: [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "Breakpoint UUID (from arm_breakpoint / list_pending)."]],
                "required": ["id"],
            ],
            isWrite: true,
            handler: { ex, args in try await ex.handleDisarmBreakpoint(args) }
        ),
        MCPTool(
            name: "list_pending",
            description: "List currently armed breakpoints and every exchange held right now awaiting a resume decision. Each pending item carries its id (pass to resume), phase (request/response), full request, and — for a response pause — the response the client would receive. Returns immediately with whatever is held; to wait for the next hold instead of polling, use wait_for_pending.",
            inputSchema: ["type": "object", "properties": [:] as [String: Any]],
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
            inputSchema: [
                "type": "object",
                "properties": [
                    "max_seconds": [
                        "type": "number",
                        "description": "How long to wait before giving up (default \(Self.defaultWaitSeconds), max \(Self.maxWaitSeconds)). Timing out is a normal result: `timedOut: true`, empty `pending`.",
                    ],
                    "breakpoint_id": ["type": "string", "description": "Only wait for holds from this armed breakpoint (from arm_breakpoint)."],
                    "limit": ["type": "integer", "description": "Stop waiting once this many exchanges are held (default 1)."],
                ],
            ],
            handler: { ex, args in try await ex.handleWaitForPending(args) }
        ),
        MCPTool(
            name: "resume",
            description: "Release a held exchange by its pending id. Continue it (optionally editing method/url/status/headers/body first) or `abort` to fail it with a 502. Request-phase edits honor method/url; response-phase edits honor status_code; both honor header + body edits. This is a write action.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "pending_id": [
                        "type": "string",
                        "description": "The held exchange's id from list_pending / wait_for_pending (where it is rendered as `id`; either argument name works here).",
                    ],
                    "abort": ["type": "boolean", "description": "Fail the exchange with a 502 instead of continuing (default false)."],
                    "method": ["type": "string", "description": "Request-phase only: replace the HTTP method."],
                    "url": ["type": "string", "description": "Request-phase only: replace the full URL."],
                    "status_code": ["type": "integer", "description": "Response-phase only: replace the status code."],
                    "set_headers": ["type": "object", "description": "Header name/value pairs to add or overwrite."],
                    "remove_headers": ["type": "array", "items": ["type": "string"], "description": "Header names to remove."],
                    "body": ["type": "string", "description": "Replacement body (UTF-8)."],
                    "clear_body": ["type": "boolean", "description": "Send an empty body (ignored if `body` is set)."],
                ],
                "required": ["pending_id"],
            ],
            isWrite: true,
            handler: { ex, args in try await ex.handleResume(args) }
        ),
        MCPTool(
            name: "get_certificate_status",
            description: "Get the HTTPS-interception root CA status: whether it exists, whether it's trusted on this machine, its SHA-256 fingerprint, expiry, and exported PEM path.",
            inputSchema: ["type": "object", "properties": [:] as [String: Any]],
            handler: { ex, args in try await ex.handleGetCertificateStatus(args) }
        ),
        MCPTool(
            name: "export_ca_certificate",
            description: "Write Loom's root CA certificate (PEM) to disk so it can be trusted, and return the file path. This is a write action.",
            inputSchema: ["type": "object", "properties": [:] as [String: Any]],
            isWrite: true,
            handler: { ex, args in try await ex.handleExportCACertificate(args) }
        ),
        MCPTool(
            name: "get_ssl_scope",
            description: "Get the SSL-proxying scope: whether interception is enabled and the include/exclude host globs. Hosts matching an include glob (and no exclude glob) are MITM-decrypted; everything else is blind-tunneled.",
            inputSchema: ["type": "object", "properties": [:] as [String: Any]],
            handler: { ex, args in try await ex.handleGetSSLScope(args) }
        ),
        MCPTool(
            name: "set_ssl_scope",
            description: "Set the SSL-proxying scope. Enables/disables HTTPS interception and replaces the include/exclude host globs (e.g. \"*.example.com\"). exclude doubles as the pinned/pass-through list. This is a write action.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "enabled": ["type": "boolean", "description": "Master switch for HTTPS interception."],
                    "include": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Host globs to decrypt, e.g. [\"*.example.com\", \"api.test\"].",
                    ],
                    "exclude": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Host globs to pass through untouched (pinned hosts).",
                    ],
                ],
            ],
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
            inputSchema: ["type": "object", "properties": [:] as [String: Any]],
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
            inputSchema: [
                "type": "object",
                "properties": [
                    "host_pattern": [
                        "type": "string",
                        "description": "Hosts to present this identity to, e.g. \"api.corp.example\" or \"*.corp.example\".",
                    ],
                    "pkcs12_base64": [
                        "type": "string",
                        "description": "Base64 of the PKCS#12 (.p12/.pfx) bundle holding the leaf, chain and private key.",
                    ],
                    "passphrase": [
                        "type": "string",
                        "description": "Passphrase for the bundle. Omit for an unprotected export.",
                    ],
                    "label": ["type": "string", "description": "Name for the operator's list (defaults to host_pattern)."],
                    "enabled": ["type": "boolean", "description": "Present this identity (default true)."],
                    "id": ["type": "string", "description": "Replace the identity with this id instead of adding one."],
                ],
                "required": ["host_pattern", "pkcs12_base64"],
            ],
            isWrite: true,
            handler: { ex, args in try await ex.handleSetClientCertificate(args) }
        ),
        MCPTool(
            name: "delete_client_certificate",
            description: "Remove a mutual-TLS client identity by id (from list_client_certificates). Hosts it covered will go back to failing the handshake if they require one. This is a write action.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The identity's id."],
                ],
                "required": ["id"],
            ],
            isWrite: true,
            handler: { ex, args in try await ex.handleDeleteClientCertificate(args) }
        ),
        MCPTool(
            name: "export_har",
            description: """
            Export captured flows to a HAR 1.2 file (readable by Chrome DevTools / Charles / \
            Proxyman, and by Loom's own import_har) and return the path. Optionally filter by \
            host and cap the count.

            Set `redact: true` when the file is going anywhere — a ticket, a chat, a CI \
            artifact. It replaces credential-bearing header values and query parameters with \
            `<redacted>` (the header stays, so a reader can tell a scrubbed token from an absent \
            one). It does NOT touch bodies or WebSocket frames: add `redact_bodies: true` for \
            those, which blanks them while keeping their sizes. A password in a login POST body \
            survives `redact: true` alone. Redaction is off by default because a debugging \
            export usually needs the token — that is often the bug. This is a write action \
            (writes a file).
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "host": ["type": "string", "description": "Only include flows whose host contains this string."],
                    "limit": ["type": "integer", "description": "Max flows to include (default 1000, newest first)."],
                    "filename": ["type": "string", "description": "Output file name (basename only; a .har suffix is added if missing). Written under ~/Library/Application Support/com.loom/exports/. Defaults to loom-export.har."],
                    "redact": [
                        "type": "boolean",
                        "description": "Scrub credentials: Authorization/Cookie/API-key headers and token-ish query parameters become `<redacted>`.",
                    ],
                    "redact_headers": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Extra header names to scrub, on top of the built-in set (implies redact).",
                    ],
                    "redact_bodies": [
                        "type": "boolean",
                        "description": "Drop request/response bodies and WebSocket frame payloads, keeping their sizes (implies redact). Use when you can't audit every payload — which is most of the time if the file is leaving the machine.",
                    ],
                ],
            ],
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
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Path to the .har file (~ is expanded)."],
                    "label": ["type": "string", "description": "What to record as `importedFrom` (defaults to the file name)."],
                ],
                "required": ["path"],
            ],
            isWrite: true,
            handler: { ex, args in try await ex.handleImportHAR(args) }
        ),
        MCPTool(
            name: "list_rules",
            description: "List traffic rules and the master rules switch. Without arguments, returns all rules with mock/rewrite bodies truncated. Pass `id` to return that single rule with full (untruncated) bodies.",
            inputSchema: [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "Optional rule UUID — return just this rule, with full bodies."]],
            ],
            handler: { ex, args in try await ex.handleListRules(args) }
        ),
        MCPTool(
            name: "set_rule",
            description: "Create or update a traffic rule (upsert). Omit `id` to create; pass `id` to update an existing rule. A rule matches requests by URL pattern (+ optional methods) and acts on them — mock the response, map to another origin or a local file, rewrite request/response headers or bodies, block, or delay. On update, provided fields replace the existing ones (match/actions are replaced whole, not merged); toggle a single rule with just {id, enabled}. Rules apply to live traffic and replays, in list order. The reply carries `effective` — whether this rule will actually affect traffic — plus `ineffectiveReason` when it will not (most often the rules master switch is off, which silently neutralises every rule). Check it before reporting that a mock is in place. This is a write action.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Rule UUID to update. Omit to create a new rule."],
                    "name": ["type": "string", "description": "Short human-readable rule name (shows in flow audit trails). Required when creating."],
                    "comment": ["type": "string", "description": "Optional note on why the rule exists."],
                    "group": ["type": "string", "description": "Optional group label (e.g. one group per scenario); a whole group can be toggled with set_group_enabled. On update, pass \"\" to ungroup."],
                    "enabled": ["type": "boolean", "description": "Default true on create."],
                    "match": Self.matchSchema,
                    "actions": Self.actionsSchema,
                ],
                "required": [] as [String],
            ],
            isWrite: true,
            handler: { ex, args in try await ex.handleSetRule(args) }
        ),
        MCPTool(
            name: "delete_rule",
            description: "Delete a traffic rule by id. This is a write action.",
            inputSchema: [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "Rule UUID."]],
                "required": ["id"],
            ],
            isWrite: true,
            handler: { ex, args in try await ex.handleDeleteRule(args) }
        ),
        MCPTool(
            name: "set_rules_enabled",
            description: "Master switch for the rule engine. When off, no rule is applied regardless of per-rule flags. This is a write action.",
            inputSchema: [
                "type": "object",
                "properties": ["enabled": ["type": "boolean"]],
                "required": ["enabled"],
            ],
            isWrite: true,
            handler: { ex, args in try await ex.handleSetRulesEnabled(args) }
        ),
        MCPTool(
            name: "set_group_enabled",
            description: "Enable or disable every rule in a group at once (e.g. switch debugging scenarios). This is a write action.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "group": ["type": "string", "description": "Group label as shown in list_rules."],
                    "enabled": ["type": "boolean"],
                ],
                "required": ["group", "enabled"],
            ],
            isWrite: true,
            handler: { ex, args in try await ex.handleSetGroupEnabled(args) }
        ),
    ]

    /// Shared `match` schema for create_rule / update_rule.
    static var matchSchema: [String: Any] {
        [
            "type": "object",
            "description": "What traffic the rule applies to, matched against the original client request.",
            "properties": [
                "url_pattern": [
                    "type": "string",
                    "description": "Matched against the full URL. Glob by default: `*` matches any characters and the pattern must cover the whole URL; without any `*` it is a prefix match (query strings still match). With is_regex it is an unanchored, case-insensitive regular expression.",
                ],
                "is_regex": ["type": "boolean", "description": "Treat url_pattern as a regular expression (default false)."],
                "is_exact": ["type": "boolean", "description": "Require url_pattern to equal the full URL exactly, instead of the default prefix/glob match (ignored when is_regex). Default false."],
                "host_pattern": ["type": "string", "description": "Optional host glob (e.g. *.example.com) matched against the URL host; combines with url_pattern."],
                "query": ["type": "object", "description": "Optional query predicates: each key must be present and equal its value, or \"*\" to require the key with any value. Order-independent."],
                "source_app": [
                    "type": "string",
                    "description": "Optional originating-app predicate: bundle id or display name (see list_devices / a flow's sourceApp), case-insensitive. This is how you scope a rule to one client — mock it for the app under test and leave the browser alone. Traffic Loom can't attribute to a local process (a LAN device has no local pid) never matches an app-scoped rule.",
                ],
                "device_ip": [
                    "type": "string",
                    "description": "Optional originating-device predicate: the device's IP as seen by the proxy (see list_devices). Scopes a rule to one phone/machine; unattributed traffic never matches.",
                ],
                "methods": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "HTTP methods to match, e.g. [\"GET\"]. Empty/omitted = all methods.",
                ],
            ],
            "required": ["url_pattern"],
        ]
    }

    /// Shared `actions` schema for create_rule / update_rule.
    static var actionsSchema: [String: Any] {
        [
            "type": "object",
            "description": "What to do with matching traffic. Set any combination. block beats mock_response beats map_local when several short-circuits match; request rewrites compose in rule order.",
            "properties": [
                "block": ["type": "boolean", "description": "Refuse the request with 403; the upstream is never contacted."],
                "mock_response": [
                    "type": "object",
                    "description": "Short-circuit with a synthesized response; the upstream is never contacted.",
                    "properties": [
                        "status_code": ["type": "integer", "description": "Default 200."],
                        "headers": ["type": "object", "description": "Response header name/value pairs."],
                        "body": ["type": "string", "description": "UTF-8 response body (e.g. a JSON document)."],
                        "body_base64": ["type": "string", "description": "Base64-encoded response body for binary payloads (images, protobuf, gzip). Takes precedence over body."],
                        "content_type": ["type": "string", "description": "Convenience Content-Type, e.g. application/json."],
                    ],
                ],
                "map_remote": [
                    "type": "object",
                    "description": "Re-send the request to a different origin, keeping path + query.",
                    "properties": [
                        "destination": ["type": "string", "description": "Origin like http://127.0.0.1:3001 (scheme + host + optional port)."],
                        "exclude": ["type": "string", "description": "URLs matching this glob/regex are left un-redirected."],
                        "keep_host_header": ["type": "boolean", "description": "Keep the original Host header instead of following the new origin."],
                    ],
                    "required": ["destination"],
                ],
                "map_local": [
                    "type": "object",
                    "description": "Serve a local file as the response; the upstream is never contacted.",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute file path."],
                        "status_code": ["type": "integer", "description": "Default 200."],
                        "content_type": ["type": "string", "description": "Default: guessed from the file extension."],
                    ],
                    "required": ["path"],
                ],
                "rewrite_request": [
                    "type": "object",
                    "description": "Mutate the outgoing request before forwarding.",
                    "properties": [
                        "method": ["type": "string"],
                        "set_headers": ["type": "object", "description": "Header name/value pairs to add or overwrite."],
                        "remove_headers": ["type": "array", "items": ["type": "string"]],
                        "body": ["type": "string", "description": "Replacement UTF-8 request body."],
                    ],
                ],
                "rewrite_response": [
                    "type": "object",
                    "description": "Mutate the response (real or mocked) before it reaches the client.",
                    "properties": [
                        "status_code": ["type": "integer"],
                        "set_headers": ["type": "object", "description": "Header name/value pairs to add or overwrite."],
                        "remove_headers": ["type": "array", "items": ["type": "string"]],
                        "body": ["type": "string", "description": "Replacement UTF-8 response body."],
                    ],
                ],
                "request_substitutions": Self.substitutionsSchema(
                    "Find/replace substitutions on the outgoing request (\"modify request\"). Applied in order."),
                "response_substitutions": Self.substitutionsSchema(
                    "Find/replace substitutions on the returned response (\"modify response\"). Applied in order."),
                "delay_ms": ["type": "integer", "description": "Hold the response back this many milliseconds (crude throttle)."],
            ],
        ]
    }

    static func substitutionsSchema(_ description: String) -> [String: Any] {
        [
            "type": "array",
            "description": description,
            "items": [
                "type": "object",
                "properties": [
                    "field": ["type": "string", "enum": ["url", "header", "body"], "description": "Which part to substitute in (url is request-side only)."],
                    "match": ["type": "string", "description": "Text or regex to find."],
                    "replacement": ["type": "string", "description": "Replacement text (regex $1 backrefs allowed)."],
                    "is_regex": ["type": "boolean", "description": "Treat match as a regular expression (default false)."],
                    "case_sensitive": ["type": "boolean", "description": "Case-sensitive match (default false)."],
                ],
                "required": ["field", "match"],
            ],
        ]
    }
}
