import Foundation
import LoomSharedModels

/// Shared accumulator for the blocking `wait_*` tools, so a collection in progress
/// is readable after the deadline cancels the task that was filling it.
private actor WaitCollector<Item: Sendable> {
    private var items: [Item] = []
    private var seen: Set<UUID> = []

    /// Append unless this id was already collected; returns the running count.
    func add(_ item: Item, id: UUID) -> Int {
        if seen.insert(id).inserted { items.append(item) }
        return items.count
    }

    var collected: [Item] { items }
}

/// Dispatches MCP `tools/call` requests to the proxy engine and renders results.
/// Read tools inspect captured traffic; `replay_flow` is the write tool that
/// makes Loom "AI-operable" rather than merely AI-readable.
struct MCPToolExecutor {
    let engine: ProxyControlling
    let appVersion: String
    let protocolVersion: String
    /// Injected by the app; nil where system-proxy control isn't available (an
    /// embedder driving the engine as a library, or a test).
    var routing: SystemRoutingControlling?

    /// `ISO8601DateFormatter` is expensive to allocate; render every timestamp
    /// through one shared instance.
    private static let iso8601 = ISO8601DateFormatter()
    /// Parse-only companion: agents (and JS clients) routinely send fractional
    /// seconds, which the default formatter rejects.
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Default / hard cap for `wait_for_flow` and `wait_for_pending`.
    ///
    /// The cap is the client's, not ours: Claude Code gives an HTTP MCP server 60 s
    /// to produce the first response byte unless the server entry raises it (the
    /// plugin's `.mcp.json` sets `timeout: 120000`, and the bridge sets its own
    /// request timeout), and aborts a call that goes 5 minutes without a byte. 60 s
    /// therefore stays inside the *unconfigured* limit, so a wait can't fail as a
    /// transport error on a client that never read our config.
    static let defaultWaitSeconds: Double = 20
    static let maxWaitSeconds: Double = 60

    /// How far back a `wait_for_flow` with no explicit window looks.
    ///
    /// Not zero, and that matters. The natural sequence is *trigger the action, then
    /// call the tool* — so by the time the call lands, the request it is waiting for
    /// may already have been captured. A strict "from now on" window would report a
    /// timeout for traffic sitting in the store, which is the exact failure the tool
    /// exists to remove. A few seconds of grace covers the gap without dragging in
    /// traffic from earlier in the session (which is what `get_recent_flows` is for).
    static let defaultWaitLookback: Double = 10

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
            Case-insensitive substring of any request or response header. Plain text \
            matches a header name or value (`authorization`, `Bearer ey`); with a colon \
            it means `name: value` and both halves must hit the same header \
            (`x-env: staging`, or `set-cookie:` for "has this header at all").
            """,
        ],
        "body_contains": [
            "type": "string",
            "description": """
            Case-insensitive substring of the captured request or response body — the \
            "which exchange carried this id/token/error string" filter. Matched over raw \
            bytes, so non-UTF-8 payloads are searched too. Combine with `host` / \
            `url_contains` / `since_seconds` to keep the scan narrow, and note a flow \
            with `captureTruncated: true` holds only a body prefix, so a miss on one of \
            those isn't proof.
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

    /// JSON metadata advertised by `tools/list`.
    var toolDefinitions: [[String: Any]] {
        [
            [
                "name": "get_version",
                "description": "Get the Loom app version and MCP protocol version.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "get_proxy_status",
                "description": """
                Get the current proxy status: running state, listen address, captured flow count, \
                whether recording is paused, and whether this Mac's own traffic is actually routed \
                through Loom (`systemProxy`). Check this first when a capture comes back empty — \
                "nothing happened" and "nothing was pointed at the proxy" look identical otherwise. \
                `systemProxy: "unavailable"` means this build can't inspect it, not that it's off.
                """,
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "set_system_proxy",
                "description": """
                Route this Mac's HTTP/HTTPS traffic through Loom, or stop routing it. This is what \
                makes local apps and browsers appear in the capture without configuring each one, \
                and it is the fix when `get_proxy_status` shows nothing is routed here.

                Machine-wide and visible to the human: it edits the active network service's proxy \
                settings, may ask for an admin password, and also installs a pf rule blocking QUIC \
                (UDP 443) so browsers fall back to TCP where a proxy can see them — browsers \
                default to HTTP/3, which no TCP proxy can intercept. Turn it off when you're done; \
                Loom also restores it on quit. Traffic from a phone or another device does NOT need \
                this (point that device at the proxy instead). This is a write action.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "enabled": ["type": "boolean", "description": "true = route this Mac through Loom, false = restore the previous settings."],
                    ],
                    "required": ["enabled"],
                ],
            ],
            [
                "name": "list_devices",
                "description": "List devices that have sent traffic through the proxy — this Mac plus any LAN devices (e.g. phones), each with detected platform/client (from User-Agent), flow count, and last-seen time.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "get_recent_flows",
                "description": """
                List captured HTTP flows, newest first, with method, url, status, timing and startedAt. \
                Filters (all optional, ANDed) are applied across every retained flow BEFORE `limit`, \
                so a match that isn't among the newest exchanges is still found — prefer filtering here \
                over pulling a big list and scanning it yourself. `captureTruncated: true` on a summary \
                means the recorded body/frame log is only a prefix of what actually flowed.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": Self.flowFilterProperties.merging([
                        "limit": ["type": "integer", "description": "Max flows to return after filtering (default 20)."],
                    ]) { current, _ in current },
                ],
            ],
            [
                "name": "wait_for_flow",
                "description": """
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
                "inputSchema": [
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
            ],
            [
                "name": "get_stats",
                "description": """
                Aggregate the capture instead of reading it: per-bucket flow counts, error rates, \
                and TTFB / duration percentiles, plus the slowest exchanges by id. Answers "which \
                endpoint is slow", "what share of calls to this host fail", "which app is chatty" \
                in one call — don't pull flow summaries and do the arithmetic yourself, and note \
                that a percentile over one page of summaries isn't a percentile.

                Takes the same filters as `get_recent_flows` (so `since_seconds` + `host` scopes it \
                to what you care about). Aggregates every retained flow that matches, and reports \
                `flowsConsidered` so you can see the sample size behind the numbers. TTFB is server \
                think-time; `duration` is the whole exchange. `sizeUnknownFlows` on a bucket means \
                its byte totals are a floor: those flows' bodies have been evicted from memory, so \
                their size is no longer known.
                """,
                "inputSchema": [
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
            ],
            [
                "name": "get_flow_detail",
                "description": "Get full request and response detail for one flow by id, including headers and body. Bodies are bounded: a body longer than `max_bytes` comes back as {truncated, preview, bytes, offset, nextOffset} — page through it by passing `body_offset: nextOffset`. A body that isn't UTF-8 text comes back as {binary, bytes} rather than an empty string.",
                "inputSchema": [
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
            ],
            [
                "name": "set_recording",
                "description": """
                Pause or resume recording captured traffic. Paused, the proxy keeps forwarding \
                (and MITM-decrypting) normally — nothing new is stored, while flows already in \
                flight still complete. Use it to stop unrelated background traffic from burying \
                what you are about to trigger. This is a write action.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "recording": ["type": "boolean", "description": "true = record, false = pause."],
                    ],
                    "required": ["recording"],
                ],
            ],
            [
                "name": "clear_flows",
                "description": """
                Discard every captured flow, in memory and on disk. Destructive and NOT undoable — \
                the human's window empties too. The point is isolation: clear, trigger the thing \
                you are debugging, then get_recent_flows sees only that. Prefer \
                `get_recent_flows` with `since_seconds` when you don't actually need to destroy \
                the existing capture. This is a write action.
                """,
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "get_audit_log",
                "description": "List recent write actions taken through Loom (replay, rules, breakpoints, ssl-scope), newest first, each with the tool name, arguments, outcome and timestamp. Read tools are never logged. Use this to review what write actions have been taken this or a prior session.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "description": "Max entries to return (default 50)."],
                    ],
                ],
            ],
            [
                "name": "replay_flow",
                "description": """
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
                "inputSchema": [
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
            ],
            [
                "name": "diff_flows",
                "description": "Diff two captured flows and report exactly what differs: request method/url, request+response headers (added/removed/changed), status code, and a line-level body diff for text payloads. Pass `base` alone to diff a replayed flow against the flow it was replayed from. This closes the capture → modify → replay → diff loop.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "base": ["type": "string", "description": "Baseline flow UUID. If `compared` is omitted, this must be a replayed flow and it is diffed against its original (replayedFrom)."],
                        "compared": ["type": "string", "description": "The changed flow UUID to compare against `base`. Optional when `base` is a replay."],
                    ],
                    "required": ["base"],
                ],
            ],
            [
                "name": "arm_breakpoint",
                "description": "Arm a breakpoint: matching traffic is HELD mid-flight so you can inspect and edit it before it continues. Match by URL pattern (+ optional methods/host/query), same as a rule. Pause the request (before it's forwarded upstream), the response (before it reaches the client), or both. Held exchanges surface in list_pending; release them with resume. This is a write action.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "match": Self.matchSchema,
                        "on_request": ["type": "boolean", "description": "Pause the request before forwarding upstream (default true)."],
                        "on_response": ["type": "boolean", "description": "Pause the response before it reaches the client (default false)."],
                        "comment": ["type": "string", "description": "Optional note on why the breakpoint exists."],
                    ],
                    "required": ["match"],
                ],
            ],
            [
                "name": "disarm_breakpoint",
                "description": "Remove an armed breakpoint by id. Exchanges it is already holding still need a resume. This is a write action.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["id": ["type": "string", "description": "Breakpoint UUID (from arm_breakpoint / list_pending)."]],
                    "required": ["id"],
                ],
            ],
            [
                "name": "list_pending",
                "description": "List currently armed breakpoints and every exchange held right now awaiting a resume decision. Each pending item carries its id (pass to resume), phase (request/response), full request, and — for a response pause — the response the client would receive. Returns immediately with whatever is held; to wait for the next hold instead of polling, use wait_for_pending.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "wait_for_pending",
                "description": """
                Block until a breakpoint holds an exchange, then return it — the second half of \
                "arm the breakpoint, trigger the app, edit the request in flight". Anything already \
                held is returned immediately, so the call can't miss a hold that landed first.

                Returns `{pending: [...], timedOut, waitedMS}` with the same item shape as \
                `list_pending`; feed an item's `id` to `resume`. Remember the exchange is holding a \
                real client connection while you think, and an unattended hold auto-proceeds \
                unchanged when the engine's hold timeout expires — so decide, then resume.
                """,
                "inputSchema": [
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
            ],
            [
                "name": "resume",
                "description": "Release a held exchange by its pending id. Continue it (optionally editing method/url/status/headers/body first) or `abort` to fail it with a 502. Request-phase edits honor method/url; response-phase edits honor status_code; both honor header + body edits. This is a write action.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "pending_id": ["type": "string", "description": "The held exchange's id from list_pending."],
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
            ],
            [
                "name": "get_certificate_status",
                "description": "Get the HTTPS-interception root CA status: whether it exists, whether it's trusted on this machine, its SHA-256 fingerprint, expiry, and exported PEM path.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "export_ca_certificate",
                "description": "Write Loom's root CA certificate (PEM) to disk so it can be trusted, and return the file path. This is a write action.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "get_ssl_scope",
                "description": "Get the SSL-proxying scope: whether interception is enabled and the include/exclude host globs. Hosts matching an include glob (and no exclude glob) are MITM-decrypted; everything else is blind-tunneled.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "set_ssl_scope",
                "description": "Set the SSL-proxying scope. Enables/disables HTTPS interception and replaces the include/exclude host globs (e.g. \"*.example.com\"). exclude doubles as the pinned/pass-through list. This is a write action.",
                "inputSchema": [
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
            ],
            [
                "name": "export_har",
                "description": "Export captured flows to a HAR 1.2 file (readable by Chrome DevTools / Charles / Proxyman) and return the path. Optionally filter by host and cap the count. This is a write action (writes a file).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "host": ["type": "string", "description": "Only include flows whose host contains this string."],
                        "limit": ["type": "integer", "description": "Max flows to include (default 1000, newest first)."],
                        "filename": ["type": "string", "description": "Output file name (basename only; a .har suffix is added if missing). Written under ~/Library/Application Support/com.loom/exports/. Defaults to loom-export.har."],
                    ],
                ],
            ],
            [
                "name": "list_rules",
                "description": "List traffic rules and the master rules switch. Without arguments, returns all rules with mock/rewrite bodies truncated. Pass `id` to return that single rule with full (untruncated) bodies.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["id": ["type": "string", "description": "Optional rule UUID — return just this rule, with full bodies."]],
                ],
            ],
            [
                "name": "set_rule",
                "description": "Create or update a traffic rule (upsert). Omit `id` to create; pass `id` to update an existing rule. A rule matches requests by URL pattern (+ optional methods) and acts on them — mock the response, map to another origin or a local file, rewrite request/response headers or bodies, block, or delay. On update, provided fields replace the existing ones (match/actions are replaced whole, not merged); toggle a single rule with just {id, enabled}. Rules apply to live traffic and replays, in list order. This is a write action.",
                "inputSchema": [
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
            ],
            [
                "name": "delete_rule",
                "description": "Delete a traffic rule by id. This is a write action.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["id": ["type": "string", "description": "Rule UUID."]],
                    "required": ["id"],
                ],
            ],
            [
                "name": "set_rules_enabled",
                "description": "Master switch for the rule engine. When off, no rule is applied regardless of per-rule flags. This is a write action.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["enabled": ["type": "boolean"]],
                    "required": ["enabled"],
                ],
            ],
            [
                "name": "set_group_enabled",
                "description": "Enable or disable every rule in a group at once (e.g. switch debugging scenarios). This is a write action.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "group": ["type": "string", "description": "Group label as shown in list_rules."],
                        "enabled": ["type": "boolean"],
                    ],
                    "required": ["group", "enabled"],
                ],
            ],
        ]
    }

    /// Shared `match` schema for create_rule / update_rule.
    private static var matchSchema: [String: Any] {
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
    private static var actionsSchema: [String: Any] {
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

    private static func substitutionsSchema(_ description: String) -> [String: Any] {
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

    /// Returns the MCP tool-result content array (a single text block) or throws
    /// a `MCPError` describing why the call failed.
    /// Name → handler registry. Paired with the same-named entries in
    /// `toolDefinitions`; `MCPServerTests` asserts the two never drift (every
    /// advertised tool has a handler). Dispatch is a lookup, not a growing switch.
    static let handlers: [String: (MCPToolExecutor, [String: Any]) async throws -> String] = [
        "get_version": { ex, args in try await ex.handleGetVersion(args) },
        "get_proxy_status": { ex, args in try await ex.handleGetProxyStatus(args) },
        "set_system_proxy": { ex, args in try await ex.handleSetSystemProxy(args) },
        "list_devices": { ex, args in try await ex.handleListDevices(args) },
        "get_recent_flows": { ex, args in try await ex.handleGetRecentFlows(args) },
        "get_stats": { ex, args in try await ex.handleGetStats(args) },
        "wait_for_flow": { ex, args in try await ex.handleWaitForFlow(args) },
        "wait_for_pending": { ex, args in try await ex.handleWaitForPending(args) },
        "get_flow_detail": { ex, args in try await ex.handleGetFlowDetail(args) },
        "get_audit_log": { ex, args in try await ex.handleGetAuditLog(args) },
        "set_recording": { ex, args in try await ex.handleSetRecording(args) },
        "clear_flows": { ex, args in try await ex.handleClearFlows(args) },
        "diff_flows": { ex, args in try await ex.handleDiffFlows(args) },
        "arm_breakpoint": { ex, args in try await ex.handleArmBreakpoint(args) },
        "disarm_breakpoint": { ex, args in try await ex.handleDisarmBreakpoint(args) },
        "list_pending": { ex, args in try await ex.handleListPending(args) },
        "resume": { ex, args in try await ex.handleResume(args) },
        "replay_flow": { ex, args in try await ex.handleReplayFlow(args) },
        "get_certificate_status": { ex, args in try await ex.handleGetCertificateStatus(args) },
        "export_ca_certificate": { ex, args in try await ex.handleExportCACertificate(args) },
        "get_ssl_scope": { ex, args in try await ex.handleGetSSLScope(args) },
        "set_ssl_scope": { ex, args in try await ex.handleSetSSLScope(args) },
        "export_har": { ex, args in try await ex.handleExportHAR(args) },
        "list_rules": { ex, args in try await ex.handleListRules(args) },
        "set_rule": { ex, args in try await ex.handleSetRule(args) },
        "delete_rule": { ex, args in try await ex.handleDeleteRule(args) },
        "set_rules_enabled": { ex, args in try await ex.handleSetRulesEnabled(args) },
        "set_group_enabled": { ex, args in try await ex.handleSetGroupEnabled(args) },
    ]

    /// Tools that touch real traffic — every one is audited (§ `call`). Kept as an
    /// explicit set rather than string-matching the "This is a write action."
    /// description marker, so a typo in a description can't silently stop auditing
    /// a write. `MCPServerTests` asserts this set matches the marked definitions.
    static let writeTools: Set<String> = [
        "replay_flow",
        "set_system_proxy",
        "set_recording",
        "clear_flows",
        "arm_breakpoint",
        "disarm_breakpoint",
        "resume",
        "export_ca_certificate",
        "set_ssl_scope",
        "export_har",
        "set_rule",
        "delete_rule",
        "set_rules_enabled",
        "set_group_enabled",
    ]

    func call(name: String, arguments: [String: Any]) async throws -> String {
        guard let handler = Self.handlers[name] else {
            throw MCPError.methodNotFound("unknown tool: \(name)")
        }
        // Read tools run straight through. Write tools are the whole reason Loom
        // exists — record each in the audit trail (success or failure) so the
        // supervising human can see what the agent did to real traffic.
        guard Self.writeTools.contains(name) else {
            return try await handler(self, arguments)
        }
        let renderedArgs = AuditEntry.truncate(Self.auditArguments(arguments))
        do {
            let result = try await handler(self, arguments)
            await engine.recordAudit(AuditEntry(
                tool: name, succeeded: true,
                arguments: renderedArgs, detail: AuditEntry.truncate(result)
            ))
            return result
        } catch {
            let message: String
            switch error {
            case let failure as MCPToolFailure: message = failure.message
            case let mcp as MCPError: message = mcp.message
            default: message = error.localizedDescription
            }
            await engine.recordAudit(AuditEntry(
                tool: name, succeeded: false,
                arguments: renderedArgs, detail: AuditEntry.truncate(message)
            ))
            throw error
        }
    }

    /// Render a tool's arguments as compact JSON for the audit trail. Falls back
    /// to `String(describing:)` for the rare non-JSON value. Truncation is applied
    /// by the caller (whole-string, so we don't split a key from its value).
    private static func auditArguments(_ arguments: [String: Any]) -> String {
        guard !arguments.isEmpty else { return "{}" }
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return String(describing: arguments) }
        return string
    }

    // MARK: - Handlers (one per tool)

    private func handleGetVersion(_ arguments: [String: Any]) async throws -> String {
        prettyJSON([
            "app": "Loom",
            "appVersion": appVersion,
            "protocolVersion": protocolVersion,
        ])
    }

    private func handleGetProxyStatus(_ arguments: [String: Any]) async throws -> String {
        let status = await engine.status()
        var payload: [String: Any] = [
            "isRunning": status.isRunning,
            "port": status.port,
            "listenHost": status.listenHost,
            "lanReachable": status.isLANReachable,
            "capturedCount": status.capturedCount,
            "isRecording": status.isRecording,
        ]
        // Three-valued on purpose: routed / not routed / can't tell. Collapsing the
        // third into `false` would have an agent "fix" a routing problem that it has
        // no way to observe, and report success it can't verify.
        if let routing {
            payload["systemProxy"] = await routing.isSystemProxyActive() ? "on" : "off"
        } else {
            payload["systemProxy"] = "unavailable"
        }
        return prettyJSON(payload)
    }

    private func handleSetSystemProxy(_ arguments: [String: Any]) async throws -> String {
        guard let enabled = arguments["enabled"] as? Bool else {
            throw MCPError.invalidParams("`enabled` must be a boolean")
        }
        guard let routing else {
            throw MCPToolFailure(
                "System-proxy control isn't available here (Loom's engine is running without the app's "
                + "network configuration). Point the client at the proxy manually instead."
            )
        }
        let status = await engine.status()
        guard status.isRunning || !enabled else {
            throw MCPToolFailure("The proxy isn't running, so there is nothing to route traffic to.")
        }
        let result = await routing.setSystemProxy(enabled: enabled)
        guard result.ok else {
            throw MCPToolFailure(result.message ?? "The system proxy change failed.")
        }
        // Read the state back rather than reporting the intent: this path goes through
        // `networksetup` (and an admin prompt on some accounts), and "it returned ok"
        // is not the same as "traffic is now routed here".
        let active = await routing.isSystemProxyActive()
        return prettyJSON([
            "systemProxy": active ? "on" : "off",
            "requested": enabled ? "on" : "off",
            "port": status.port,
            "detail": result.message ?? (enabled ? "This Mac's traffic now routes through Loom." : "Previous proxy settings restored."),
        ])
    }

    private func handleListDevices(_ arguments: [String: Any]) async throws -> String {
        let devices = await engine.connectedDevices()
        return prettyJSON(devices.map(Self.deviceSummary))
    }

    private func handleGetRecentFlows(_ arguments: [String: Any]) async throws -> String {
        let limit = (arguments["limit"] as? Int) ?? 20
        let query = try Self.flowQuery(from: arguments)
        let flows = await engine.recentFlows(matching: query, limit: limit)
        return prettyJSON(flows.map(Self.flowSummary))
    }

    /// Upper bound on the flows one `get_stats` call aggregates. Set above the engine's
    /// in-memory ring capacity so it means "everything retained in memory" rather than
    /// a page — like `get_recent_flows`, the scan is over the ring, not the whole
    /// SQLite history.
    static let statsScanCap = 5_000

    private func handleGetStats(_ arguments: [String: Any]) async throws -> String {
        let query = try Self.flowQuery(from: arguments)
        let grouping = try Self.grouping(from: arguments)
        let limit = (arguments["limit"] as? Int) ?? 10
        let slowest = (arguments["slowest"] as? Int) ?? 3

        let flows = await engine.recentFlows(matching: query, limit: Self.statsScanCap)
        let stats = FlowStats.compute(flows: flows, grouping: grouping, limit: limit, slowest: slowest)

        var payload: [String: Any] = [
            "groupBy": grouping.rawValue,
            "flowsConsidered": stats.total.flows,
            "total": Self.statsBucket(stats.total),
            "buckets": stats.buckets.map(Self.statsBucket),
            "bucketsOmitted": stats.bucketsOmitted,
            "slowest": stats.slowest.map { slow in
                var item: [String: Any] = ["id": slow.id.uuidString, "method": slow.method, "url": slow.url]
                if let statusCode = slow.statusCode { item["status"] = statusCode }
                if let ttfbMS = slow.ttfbMS { item["ttfbMS"] = ttfbMS }
                if let durationMS = slow.durationMS { item["durationMS"] = durationMS }
                return item
            },
        ]
        if let earliest = stats.earliest { payload["from"] = Self.iso8601.string(from: earliest) }
        if let latest = stats.latest { payload["to"] = Self.iso8601.string(from: latest) }
        return prettyJSON(payload)
    }

    private static func statsBucket(_ bucket: FlowStats.Bucket) -> [String: Any] {
        var out: [String: Any] = [
            "key": bucket.key,
            "flows": bucket.flows,
            "errors": bucket.errors,
            // Rounded: three decimals is finer than any capture-sized sample justifies.
            "errorRate": (bucket.errorRate * 1000).rounded() / 1000,
            "statusClasses": bucket.statusClasses,
            "requestBytes": bucket.requestBytes,
            "responseBytes": bucket.responseBytes,
        ]
        if bucket.failed > 0 { out["failed"] = bucket.failed }
        if bucket.inFlight > 0 { out["inFlight"] = bucket.inFlight }
        if let ttfb = bucket.ttfb { out["ttfbMS"] = distribution(ttfb) }
        if let duration = bucket.duration { out["durationMS"] = distribution(duration) }
        // Only surfaced when it applies — but never omitted when it does, because it is
        // the difference between "this host sent 4 MB" and "at least 4 MB".
        if bucket.sizeUnknownFlows > 0 { out["sizeUnknownFlows"] = bucket.sizeUnknownFlows }
        return out
    }

    private static func distribution(_ distribution: FlowStats.Distribution) -> [String: Any] {
        ["p50": distribution.p50, "p95": distribution.p95, "max": distribution.max, "samples": distribution.samples]
    }

    static func grouping(from arguments: [String: Any]) throws -> FlowGrouping {
        guard let raw = arguments["group_by"] else { return .host }
        guard let text = raw as? String, let grouping = FlowGrouping(rawValue: text.lowercased()) else {
            throw MCPError.invalidParams(
                "`group_by` must be one of: \(FlowGrouping.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }
        return grouping
    }

    /// How much of an exchange `wait_for_flow` waits for.
    enum WaitUntil: String {
        /// The request has been seen; nothing is known about the response yet.
        case request
        /// The status line is known (streaming, completed or failed).
        case response
        /// Terminal: completed or failed, so bodies and timing are final.
        case completed

        func isSatisfied(by flow: Flow) -> Bool {
            switch self {
            case .request:
                return true
            case .response:
                return flow.statusCode != nil || flow.error != nil
            case .completed:
                return flow.completedAt != nil || flow.error != nil
            }
        }
    }

    /// Wait for traffic instead of polling for it.
    ///
    /// Two properties make this safe to rely on, and both come from the ordering
    /// here rather than from anything the caller does:
    ///
    /// 1. **No gap between looking and listening.** The stream is subscribed
    ///    *before* the store is read, so a flow arriving in between is delivered on
    ///    the stream rather than falling into the hole a check-then-subscribe order
    ///    would leave.
    /// 2. **A timeout costs nothing.** The match is a query over the retained
    ///    capture, not the consumption of an event: whatever this call misses is
    ///    still in the store for the next one. So a client-side abort, or the
    ///    caller's own `max_seconds`, degrades to polling — never to lost traffic.
    ///    `waitStartedAt` comes back so a retry can resume from exactly here.
    private func handleWaitForFlow(_ arguments: [String: Any]) async throws -> String {
        let seconds = try Self.waitSeconds(from: arguments)
        let limit = max(1, (arguments["limit"] as? Int) ?? 1)
        let until = try Self.waitUntil(from: arguments)
        var query = try Self.flowQuery(from: arguments)
        let startedWaitingAt = Date()
        // A wait needs *some* window: inheriting `get_recent_flows`' match-everything
        // default would return the oldest retained flow instantly, which is never what
        // "wait for the request I'm about to trigger" means. See `defaultWaitLookback`
        // for why the default window starts slightly in the past rather than at `now`.
        if query.since == nil {
            query.since = startedWaitingAt.addingTimeInterval(-Self.defaultWaitLookback)
        }
        let windowFrom = query.since ?? startedWaitingAt

        let stream = await engine.flowStream()
        let existing = await engine.recentFlows(matching: query, limit: limit)
            .filter { until.isSatisfied(by: $0) }
        if !existing.isEmpty {
            // The store hands back newest-first; a wait reads better oldest-first
            // (the order the exchanges actually happened in).
            return waitResult(
                matched: Array(existing.reversed()), timedOut: false,
                startedWaitingAt: startedWaitingAt, windowFrom: windowFrom
            )
        }

        let matched = await Self.waitCollecting(
            from: stream, id: \.id, seconds: seconds, limit: limit,
            accepts: { until.isSatisfied(by: $0) && query.matches($0) }
        )
        return waitResult(
            matched: matched, timedOut: matched.count < limit,
            startedWaitingAt: startedWaitingAt, windowFrom: windowFrom
        )
    }

    private func waitResult(
        matched: [Flow], timedOut: Bool, startedWaitingAt: Date, windowFrom: Date
    ) -> String {
        prettyJSON([
            "matched": matched.map(Self.flowSummary),
            "timedOut": timedOut,
            "waitedMS": Int(Date().timeIntervalSince(startedWaitingAt) * 1000),
            // The retry cursor: the start of the window this call considered. Passing
            // it back as `since` on a follow-up call makes the retry gapless, which is
            // what keeps a timeout (ours or the transport's) harmless.
            "windowFrom": Self.iso8601.string(from: windowFrom),
        ])
    }

    /// Wait for a breakpoint to hold an exchange. Same subscribe-then-check ordering
    /// as `wait_for_flow`, for the same reason — except a hold is *not* retained
    /// state: it is a live connection that auto-proceeds when the engine's hold
    /// timeout expires, so a missed notification really would be a missed exchange.
    private func handleWaitForPending(_ arguments: [String: Any]) async throws -> String {
        let seconds = try Self.waitSeconds(from: arguments)
        let limit = max(1, (arguments["limit"] as? Int) ?? 1)
        let breakpointID = try Self.optionalUUID(arguments["breakpoint_id"], field: "breakpoint_id")
        let startedWaitingAt = Date()

        let accepts: @Sendable (PendingBreakpoint) -> Bool = { pending in
            breakpointID == nil || pending.breakpointID == breakpointID
        }

        let stream = await engine.pendingBreakpointStream()
        let alreadyHeld = await engine.pendingBreakpoints().filter(accepts)
        if !alreadyHeld.isEmpty {
            return pendingWaitResult(alreadyHeld, timedOut: false, startedWaitingAt: startedWaitingAt)
        }

        let held = await Self.waitCollecting(
            from: stream, id: \.id, seconds: seconds, limit: limit, accepts: accepts
        )
        return pendingWaitResult(held, timedOut: held.count < limit, startedWaitingAt: startedWaitingAt)
    }

    private func pendingWaitResult(
        _ pending: [PendingBreakpoint], timedOut: Bool, startedWaitingAt: Date
    ) -> String {
        prettyJSON([
            "pending": pending.map(Self.pendingBreakpoint),
            "timedOut": timedOut,
            "waitedMS": Int(Date().timeIntervalSince(startedWaitingAt) * 1000),
        ])
    }

    /// Accumulate accepted items off `stream` until `limit` is reached or `seconds`
    /// elapse, whichever comes first.
    ///
    /// Partial results survive the deadline — the collector is shared state, not the
    /// racing task's return value, so a wait for 3 flows that saw 2 reports those 2
    /// instead of pretending it saw nothing. Deduplicated by id because a flow is
    /// emitted several times as it progresses (pending → streaming → completed), and
    /// `until: request` would otherwise count one exchange repeatedly.
    private static func waitCollecting<Item: Sendable>(
        from stream: AsyncStream<Item>,
        id: @escaping @Sendable (Item) -> UUID,
        seconds: Double,
        limit: Int,
        accepts: @escaping @Sendable (Item) -> Bool
    ) async -> [Item] {
        let collector = WaitCollector<Item>()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await item in stream where accepts(item) {
                    if await collector.add(item, id: id(item)) >= limit { break }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            // Whichever finishes first — a full collection or the deadline — ends the
            // wait; cancelling the group tears down the other. Cancellation of the
            // *calling* task (the MCP client hung up mid-call) lands here too, so a
            // dropped connection doesn't leave a waiter parked for the full duration.
            await group.next()
            group.cancelAll()
        }
        return await collector.collected
    }

    static func waitSeconds(from arguments: [String: Any]) throws -> Double {
        let raw: Double
        switch arguments["max_seconds"] {
        case let value as Double: raw = value
        case let value as Int: raw = Double(value)
        case nil: return defaultWaitSeconds
        default: throw MCPError.invalidParams("`max_seconds` must be a number")
        }
        guard raw > 0 else { throw MCPError.invalidParams("`max_seconds` must be greater than 0") }
        // Clamped rather than rejected: a client asking for a longer wait than the
        // MCP transport will tolerate gets the longest safe one, not an error.
        return min(raw, maxWaitSeconds)
    }

    /// An optional UUID argument. A present-but-malformed value is an error, never a
    /// silently ignored filter.
    static func optionalUUID(_ raw: Any?, field: String) throws -> UUID? {
        guard let raw else { return nil }
        guard let text = raw as? String, let id = UUID(uuidString: text) else {
            throw MCPError.invalidParams("`\(field)` must be a UUID string")
        }
        return id
    }

    static func waitUntil(from arguments: [String: Any]) throws -> WaitUntil {
        guard let raw = arguments["until"] else { return .completed }
        guard let text = raw as? String, let until = WaitUntil(rawValue: text.lowercased()) else {
            throw MCPError.invalidParams("`until` must be one of: completed, response, request")
        }
        return until
    }

    /// Parse the `get_recent_flows` filter arguments. Malformed input is rejected
    /// rather than silently ignored: a filter that quietly doesn't apply would hand
    /// an agent unfiltered traffic it believes is filtered — worse than an error.
    static func flowQuery(from arguments: [String: Any]) throws -> FlowQuery {
        var query = FlowQuery()
        query.host = arguments["host"] as? String
        query.urlContains = arguments["url_contains"] as? String
        query.deviceIP = arguments["device_ip"] as? String
        query.sourceApp = arguments["source_app"] as? String
        query.headerContains = arguments["header_contains"] as? String
        query.bodyContains = arguments["body_contains"] as? String
        query.onlyErrors = (arguments["only_errors"] as? Bool) ?? false

        switch arguments["method"] {
        case let single as String: query.methods = [single]
        case let many as [String]: query.methods = many
        case nil: break
        default: throw MCPError.invalidParams("`method` must be a string or an array of strings")
        }

        query.statusMin = arguments["status_min"] as? Int
        query.statusMax = arguments["status_max"] as? Int
        switch arguments["status"] {
        case let exact as Int:
            query.statusMin = exact
            query.statusMax = exact
        case let text as String:
            guard let range = Self.statusClass(text) else {
                throw MCPError.invalidParams("`status` must be a number (500) or a class like \"5xx\"")
            }
            query.statusMin = range.lowerBound
            query.statusMax = range.upperBound
        case nil: break
        default: throw MCPError.invalidParams("`status` must be a number or a string like \"5xx\"")
        }

        if let seconds = arguments["since_seconds"] as? Double {
            query.since = Date().addingTimeInterval(-abs(seconds))
        } else if let seconds = arguments["since_seconds"] as? Int {
            query.since = Date().addingTimeInterval(-abs(Double(seconds)))
        }
        if let raw = arguments["since"] as? String {
            guard let date = Self.iso8601.date(from: raw) ?? Self.iso8601Fractional.date(from: raw) else {
                throw MCPError.invalidParams("`since` must be an ISO-8601 timestamp")
            }
            query.since = date
        }
        return query
    }

    /// `"5xx"` → 500...599. Accepts any single leading digit; anything else is nil.
    private static func statusClass(_ text: String) -> ClosedRange<Int>? {
        let lowered = text.lowercased()
        guard lowered.count == 3, lowered.hasSuffix("xx"),
              let digit = lowered.first?.wholeNumberValue, (1 ... 5).contains(digit)
        else { return nil }
        return (digit * 100) ... (digit * 100 + 99)
    }

    private func handleGetFlowDetail(_ arguments: [String: Any]) async throws -> String {
        guard let idString = arguments["id"] as? String, let id = UUID(uuidString: idString) else {
            throw MCPError.invalidParams("`id` must be a flow UUID string")
        }
        guard let flow = await engine.flow(id: id) else {
            throw MCPToolFailure("no flow with id \(idString)")
        }
        return prettyJSON(Self.flowDetail(
            flow,
            offset: max(0, (arguments["body_offset"] as? Int) ?? 0),
            maxBytes: max(1, (arguments["max_bytes"] as? Int) ?? Self.defaultBodyBytes),
            webSocketLimit: max(1, (arguments["ws_limit"] as? Int) ?? Self.defaultWebSocketMessages)
        ))
    }

    private func handleSetRecording(_ arguments: [String: Any]) async throws -> String {
        guard let recording = arguments["recording"] as? Bool else {
            throw MCPError.invalidParams("`recording` must be a boolean")
        }
        await engine.setRecording(recording)
        return prettyJSON(["isRecording": recording])
    }

    /// Destructive: wipes the ring and the durable store. Audited like every write,
    /// and the engine broadcasts the clear so the human's window empties too rather
    /// than showing flows that no longer exist.
    private func handleClearFlows(_ arguments: [String: Any]) async throws -> String {
        let before = await engine.status().capturedCount
        await engine.clearFlows()
        return prettyJSON(["cleared": before])
    }

    private func handleGetAuditLog(_ arguments: [String: Any]) async throws -> String {
        let limit = (arguments["limit"] as? Int) ?? 50
        let entries = await engine.recentAuditEntries(limit: limit)
        return prettyJSON(entries.map(Self.auditSummary))
    }

    private func handleDiffFlows(_ arguments: [String: Any]) async throws -> String {
        guard let baseString = arguments["base"] as? String, let baseID = UUID(uuidString: baseString) else {
            throw MCPError.invalidParams("`base` must be a flow UUID string")
        }
        guard let baseFlow = await engine.flow(id: baseID) else {
            throw MCPToolFailure("no flow with id \(baseString)")
        }

        // Resolve the two sides. Explicit `compared` wins; otherwise diff a replay
        // against the flow it was replayed from (base = original, compared = replay),
        // which is the natural one-argument "how did my replay change things" call.
        let base: Flow
        let compared: Flow
        if let comparedString = arguments["compared"] as? String {
            guard let comparedID = UUID(uuidString: comparedString) else {
                throw MCPError.invalidParams("`compared` must be a flow UUID string")
            }
            guard let comparedFlow = await engine.flow(id: comparedID) else {
                throw MCPToolFailure("no flow with id \(comparedString)")
            }
            base = baseFlow
            compared = comparedFlow
        } else {
            guard let originalID = baseFlow.replayedFrom else {
                throw MCPToolFailure("flow \(baseString) was not replayed from another flow — pass `compared` explicitly")
            }
            guard let original = await engine.flow(id: originalID) else {
                throw MCPToolFailure("original flow \(originalID.uuidString) (replayedFrom) is no longer in the store — pass `compared` explicitly")
            }
            base = original
            compared = baseFlow
        }

        return prettyJSON(FlowDiff.diff(base: base, compared: compared))
    }

    // MARK: Breakpoints

    private func handleArmBreakpoint(_ arguments: [String: Any]) async throws -> String {
        guard let matchRaw = arguments["match"] as? [String: Any],
              let match = Self.ruleMatch(from: matchRaw) else {
            throw MCPError.invalidParams("`match` with `url_pattern` is required")
        }
        let breakpoint = Breakpoint(
            match: match,
            onRequest: (arguments["on_request"] as? Bool) ?? true,
            onResponse: (arguments["on_response"] as? Bool) ?? false,
            comment: arguments["comment"] as? String
        )
        do {
            try await engine.armBreakpoint(breakpoint)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON(Self.breakpoint(breakpoint))
    }

    private func handleDisarmBreakpoint(_ arguments: [String: Any]) async throws -> String {
        guard let idString = arguments["id"] as? String, let id = UUID(uuidString: idString) else {
            throw MCPError.invalidParams("`id` must be a breakpoint UUID string")
        }
        do {
            try await engine.disarmBreakpoint(id: id)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON(["disarmed": idString])
    }

    private func handleListPending(_ arguments: [String: Any]) async throws -> String {
        let armed = await engine.armedBreakpoints()
        let pending = await engine.pendingBreakpoints()
        return prettyJSON([
            "armed": armed.map(Self.breakpoint),
            "pending": pending.map(Self.pendingBreakpoint),
        ])
    }

    private func handleResume(_ arguments: [String: Any]) async throws -> String {
        guard let idString = arguments["pending_id"] as? String, let id = UUID(uuidString: idString) else {
            throw MCPError.invalidParams("`pending_id` must be a held-breakpoint UUID string")
        }
        let abort = (arguments["abort"] as? Bool) ?? false
        var setHeaders: [HeaderPair]?
        if let raw = arguments["set_headers"] as? [String: Any] {
            setHeaders = raw.map { HeaderPair(name: $0.key, value: String(describing: $0.value)) }
        }
        let body: BodyOverride
        if let bodyString = arguments["body"] as? String {
            body = .replace(Data(bodyString.utf8))
        } else if (arguments["clear_body"] as? Bool) == true {
            body = .clear
        } else {
            body = .keep
        }
        let edit = BreakpointEdit(
            method: arguments["method"] as? String,
            url: arguments["url"] as? String,
            statusCode: arguments["status_code"] as? Int,
            setHeaders: setHeaders,
            removeHeaders: arguments["remove_headers"] as? [String],
            body: body
        )
        do {
            try await engine.resumeBreakpoint(pendingID: id, abort: abort, edit: edit)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON(["resumed": idString, "aborted": abort])
    }

    /// Hard caps on one batch replay. These are real requests to a real upstream, so
    /// the ceiling is deliberately low, and asking for more is an error rather than a
    /// silent clamp — a caller sizing a repro ("did it fail 3 times in 200?") must not
    /// be handed 50 and told nothing.
    static let maxReplayCount = 50
    static let maxReplayConcurrency = 10

    private func handleReplayFlow(_ arguments: [String: Any]) async throws -> String {
        guard let idString = arguments["id"] as? String, let id = UUID(uuidString: idString) else {
            throw MCPError.invalidParams("`id` must be a flow UUID string")
        }
        let overrides = Self.overrides(from: arguments)
        let count = try Self.boundedInt(
            arguments["count"], field: "count", default: 1, max: Self.maxReplayCount
        )
        let concurrency = try Self.boundedInt(
            arguments["concurrency"], field: "concurrency", default: 1, max: Self.maxReplayConcurrency
        )

        // One replay keeps the single-flow shape it has always had — the common case
        // shouldn't pay for batch scaffolding, in tokens or in reading effort.
        guard count > 1 else {
            do {
                let flow = try await engine.replay(id: id, overrides: overrides)
                return prettyJSON(Self.flowDetail(flow))
            } catch let error as ProxyControlError {
                throw MCPToolFailure(error.message)
            }
        }
        return await batchReplay(id: id, overrides: overrides, count: count, concurrency: concurrency)
    }

    /// Send the same request `count` times with at most `concurrency` in flight.
    ///
    /// A failure is data, not a thrown error: the point of replaying 20 times is to
    /// learn that 3 of them failed, which a call that gives up on the first failure
    /// can't tell you. Each attempt still records its own flow in the store (the
    /// engine does that even for a failed replay), so the batch summary is a summary,
    /// not the only record.
    private func batchReplay(
        id: UUID, overrides: ReplayOverrides, count: Int, concurrency: Int
    ) async -> String {
        let engine = self.engine
        var flows: [Flow] = []
        var failures: [String] = []

        await withTaskGroup(of: Result<Flow, Error>.self) { group in
            var launched = 0
            func launch() {
                group.addTask {
                    do { return .success(try await engine.replay(id: id, overrides: overrides)) }
                    catch { return .failure(error) }
                }
                launched += 1
            }
            // Keep the window full rather than running in lockstep rounds: with
            // concurrency 4 and count 20, a slow attempt holds up one slot, not five.
            for _ in 0 ..< min(concurrency, count) { launch() }
            while let result = await group.next() {
                switch result {
                case let .success(flow): flows.append(flow)
                case let .failure(error):
                    failures.append((error as? ProxyControlError)?.message ?? error.localizedDescription)
                }
                if launched < count { launch() }
            }
        }

        // Attempts finish out of order; report them in the order they were sent.
        flows.sort { $0.startedAt < $1.startedAt }
        let stats = FlowStats.compute(flows: flows, grouping: .none, slowest: 0)
        var payload: [String: Any] = [
            "requested": count,
            "concurrency": concurrency,
            "succeeded": flows.count,
            "failed": failures.count,
            "statusClasses": stats.total.statusClasses,
            "replays": flows.map { flow in
                var item: [String: Any] = ["id": flow.id.uuidString]
                if let status = flow.statusCode { item["status"] = status }
                if let ttfbMS = flow.ttfbMS { item["ttfbMS"] = ttfbMS }
                if let durationMS = flow.durationMS { item["durationMS"] = durationMS }
                if let error = flow.error { item["error"] = error }
                return item
            },
        ]
        if let ttfb = stats.total.ttfb { payload["ttfbMS"] = Self.distribution(ttfb) }
        if let duration = stats.total.duration { payload["durationMS"] = Self.distribution(duration) }
        // Distinct messages with counts: 20 copies of "connection refused" is one fact.
        if !failures.isEmpty {
            payload["errors"] = Dictionary(grouping: failures, by: { $0 }).map { message, occurrences in
                ["message": message, "count": occurrences.count] as [String: Any]
            }
        }
        return prettyJSON(payload)
    }

    /// A positive integer argument with a documented ceiling. Absent → `default`;
    /// present but out of range → an error naming the ceiling.
    static func boundedInt(_ raw: Any?, field: String, default fallback: Int, max ceiling: Int) throws -> Int {
        guard let raw else { return fallback }
        guard let value = raw as? Int else { throw MCPError.invalidParams("`\(field)` must be an integer") }
        guard value >= 1 else { throw MCPError.invalidParams("`\(field)` must be at least 1") }
        guard value <= ceiling else {
            throw MCPError.invalidParams("`\(field)` must be at most \(ceiling) (asked for \(value))")
        }
        return value
    }

    private func handleGetCertificateStatus(_ arguments: [String: Any]) async throws -> String {
        prettyJSON(Self.certificateStatus(await engine.certificateStatus()))
    }

    private func handleExportCACertificate(_ arguments: [String: Any]) async throws -> String {
        do {
            let url = try await engine.exportCACertificate()
            return prettyJSON([
                "path": url.path,
                "hint": "Trust it with: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \(url.path)",
            ])
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
    }

    private func handleGetSSLScope(_ arguments: [String: Any]) async throws -> String {
        prettyJSON(Self.scope(await engine.sslScope()))
    }

    private func handleSetSSLScope(_ arguments: [String: Any]) async throws -> String {
        let current = await engine.sslScope()
        let scope = SSLScope(
            enabled: (arguments["enabled"] as? Bool) ?? current.enabled,
            include: (arguments["include"] as? [String]) ?? current.include,
            exclude: (arguments["exclude"] as? [String]) ?? current.exclude
        )
        await engine.setSSLScope(scope)
        return prettyJSON(Self.scope(scope))
    }

    private func handleExportHAR(_ arguments: [String: Any]) async throws -> String {
        let limit = (arguments["limit"] as? Int) ?? 1000
        // HAR needs full request/response bodies, so hydrate (bodies live in
        // separate storage now); the list/summary tools stay on the body-free path.
        var flows = await engine.recentFlowsForExport(limit: limit)
        if let host = (arguments["host"] as? String), !host.isEmpty {
            let needle = host.lowercased()
            flows = flows.filter { ($0.host ?? "").lowercased().contains(needle) }
        }
        let data = HARExport.encode(flows, appVersion: appVersion)
        // Confine exports to the exports/ directory and take only a basename,
        // so the AI can't overwrite arbitrary user files (~/.zshrc, plists) via
        // a path argument. Any directory component in `filename` is stripped.
        let exportsDir = HandshakeStore.directory.appendingPathComponent("exports", isDirectory: true)
        let filename: String
        if let raw = arguments["filename"] as? String, !raw.isEmpty {
            let base = (raw as NSString).lastPathComponent
            guard !base.isEmpty, base != ".", base != "..", !base.hasPrefix(".") else {
                throw MCPError.invalidParams("invalid filename: \(raw)")
            }
            filename = base.hasSuffix(".har") ? base : base + ".har"
        } else {
            filename = "loom-export.har"
        }
        let url = exportsDir.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw MCPToolFailure("could not write HAR to \(url.path): \(error.localizedDescription)")
        }
        return prettyJSON(["path": url.path, "entries": flows.count])
    }

    /// `list_rules`: all rules (bodies truncated), or — with `id` — one rule with
    /// full bodies. Absorbs the former `get_rule`.
    private func handleListRules(_ arguments: [String: Any]) async throws -> String {
        if arguments["id"] != nil {
            let rule = try await existingRule(arguments)
            return prettyJSON(Self.rule(rule, truncateBodies: false))
        }
        let state = await engine.rulesState()
        return prettyJSON([
            "enabled": state.enabled,
            "count": state.rules.count,
            "rules": state.rules.map { Self.rule($0, truncateBodies: true) },
        ])
    }

    /// `set_rule`: upsert. No `id` → create (name/match/actions required); `id` →
    /// update (provided fields replace). Absorbs `create_rule` + `update_rule`.
    private func handleSetRule(_ arguments: [String: Any]) async throws -> String {
        arguments["id"] == nil
            ? try await createRule(arguments)
            : try await updateRule(arguments)
    }

    private func createRule(_ arguments: [String: Any]) async throws -> String {
        guard let ruleName = arguments["name"] as? String else {
            throw MCPError.invalidParams("`name` is required to create a rule")
        }
        guard let matchRaw = arguments["match"] as? [String: Any],
              let match = Self.ruleMatch(from: matchRaw) else {
            throw MCPError.invalidParams("`match` with `url_pattern` is required")
        }
        guard let actionsRaw = arguments["actions"] as? [String: Any] else {
            throw MCPError.invalidParams("`actions` is required")
        }
        let rule = TrafficRule(
            name: ruleName,
            comment: arguments["comment"] as? String,
            group: Self.groupName(arguments["group"]),
            isEnabled: (arguments["enabled"] as? Bool) ?? true,
            match: match,
            actions: try Self.ruleActions(from: actionsRaw)
        )
        do {
            try await engine.addRule(rule)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON(Self.rule(rule, truncateBodies: false))
    }

    private func updateRule(_ arguments: [String: Any]) async throws -> String {
        var rule = try await existingRule(arguments)
        if let newName = arguments["name"] as? String { rule.name = newName }
        if let comment = arguments["comment"] as? String { rule.comment = comment }
        if arguments["group"] is String { rule.group = Self.groupName(arguments["group"]) }
        if let enabled = arguments["enabled"] as? Bool { rule.isEnabled = enabled }
        if let matchRaw = arguments["match"] as? [String: Any] {
            guard let match = Self.ruleMatch(from: matchRaw) else {
                throw MCPError.invalidParams("`match` must contain `url_pattern`")
            }
            rule.match = match
        }
        if let actionsRaw = arguments["actions"] as? [String: Any] {
            rule.actions = try Self.ruleActions(from: actionsRaw)
        }
        do {
            try await engine.updateRule(rule)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON(Self.rule(rule, truncateBodies: false))
    }

    private func handleDeleteRule(_ arguments: [String: Any]) async throws -> String {
        let rule = try await existingRule(arguments)
        do {
            try await engine.deleteRule(id: rule.id)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON(["deleted": rule.id.uuidString, "name": rule.name])
    }

    private func handleSetRulesEnabled(_ arguments: [String: Any]) async throws -> String {
        guard let enabled = arguments["enabled"] as? Bool else {
            throw MCPError.invalidParams("`enabled` (boolean) is required")
        }
        await engine.setRulesEnabled(enabled)
        let state = await engine.rulesState()
        return prettyJSON(["enabled": state.enabled, "count": state.rules.count])
    }

    private func handleSetGroupEnabled(_ arguments: [String: Any]) async throws -> String {
        guard let group = Self.groupName(arguments["group"]) else {
            throw MCPError.invalidParams("`group` (non-empty string) is required")
        }
        guard let enabled = arguments["enabled"] as? Bool else {
            throw MCPError.invalidParams("`enabled` (boolean) is required")
        }
        let members = await engine.rulesState().rules.filter { $0.group == group }
        guard !members.isEmpty else {
            throw MCPToolFailure("no rules in group \"\(group)\" — see list_rules")
        }
        await engine.setGroupEnabled(group: group, enabled: enabled)
        return prettyJSON(["group": group, "enabled": enabled, "affected": members.count])
    }

    /// Resolve the `id` argument to a stored rule or throw a structured error.
    private func existingRule(_ arguments: [String: Any]) async throws -> TrafficRule {
        guard let idString = arguments["id"] as? String, let id = UUID(uuidString: idString) else {
            throw MCPError.invalidParams("`id` must be a rule UUID string")
        }
        guard let rule = await engine.rulesState().rules.first(where: { $0.id == id }) else {
            throw MCPToolFailure("no rule with id \(idString)")
        }
        return rule
    }

    // MARK: - Rendering

    private static func flowSummary(_ flow: Flow) -> [String: Any] {
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

    /// One entry for `get_audit_log`. Timestamp as ISO-8601 so the model can order
    /// them; `arguments` is already-truncated compact JSON (a string, not re-parsed).
    private static func auditSummary(_ entry: AuditEntry) -> [String: Any] {
        [
            "id": entry.id.uuidString,
            "timestamp": iso8601.string(from: entry.timestamp),
            "tool": entry.tool,
            "source": entry.source.rawValue,
            "succeeded": entry.succeeded,
            "arguments": entry.arguments,
            "detail": entry.detail,
        ]
    }

    /// One entry for `list_devices`. Dates as ISO-8601 so the model can order them.
    private static func deviceSummary(_ summary: DeviceSummary) -> [String: Any] {
        let device = summary.device
        var out: [String: Any] = [
            "ip": device.ip,
            "kind": device.kind.rawValue,
            "displayName": device.displayName,
            "flowCount": summary.flowCount,
            "lastActive": ISO8601DateFormatter().string(from: summary.lastActive),
        ]
        if let platform = device.platform { out["platform"] = platform }
        if let client = device.client { out["client"] = client }
        if let type = device.typeSummary { out["type"] = type }
        return out
    }

    /// One flow rendered for `get_flow_detail`. Bodies go through `bodyField`, so
    /// a multi-megabyte response is bounded (with a `nextOffset` to page from) and
    /// a binary payload is labelled instead of silently becoming `""` — an agent
    /// must be able to tell "no body" from "2 MB of PNG".
    private static func flowDetail(
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

    private static func certificateStatus(_ status: CertificateStatus) -> [String: Any] {
        var out: [String: Any] = [
            "isGenerated": status.isGenerated,
            "isTrusted": status.isTrusted,
        ]
        if let cn = status.commonName { out["commonName"] = cn }
        if let fp = status.sha256Fingerprint { out["sha256Fingerprint"] = fp }
        if let notAfter = status.notAfter { out["notAfter"] = Self.iso8601.string(from: notAfter) }
        if let path = status.exportedPEMPath { out["exportedPEMPath"] = path }
        return out
    }

    private static func scope(_ scope: SSLScope) -> [String: Any] {
        [
            "enabled": scope.enabled,
            "include": scope.include,
            "exclude": scope.exclude,
        ]
    }

    // MARK: - Rules parsing / rendering

    /// Normalize a group argument: empty/whitespace (or non-string) means "no group".
    private static func groupName(_ raw: Any?) -> String? {
        guard let name = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    private static func ruleMatch(from raw: [String: Any]) -> RuleMatch? {
        guard let pattern = raw["url_pattern"] as? String else { return nil }
        return RuleMatch(
            urlPattern: pattern,
            isRegex: (raw["is_regex"] as? Bool) ?? false,
            methods: (raw["methods"] as? [String]) ?? [],
            isExact: (raw["is_exact"] as? Bool) ?? false,
            hostPattern: (raw["host_pattern"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            query: (raw["query"] as? [String: String]).flatMap { $0.isEmpty ? nil : $0 },
            sourceApp: (raw["source_app"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            deviceIP: (raw["device_ip"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static func ruleActions(from raw: [String: Any]) throws -> RuleActions {
        var actions = RuleActions()

        // The route is exactly one of block/mock/map_remote/map_local. Reject more
        // than one rather than silently picking — the AI must see the conflict.
        var routes: [Route] = []
        if (raw["block"] as? Bool) == true { routes.append(.block) }
        if let mock = raw["mock_response"] as? [String: Any] {
            routes.append(.mock(MockResponseAction(
                statusCode: (mock["status_code"] as? Int) ?? 200,
                headers: headerPairs(mock["headers"]),
                bodyText: mock["body"] as? String,
                bodyBase64: mock["body_base64"] as? String,
                contentType: mock["content_type"] as? String
            )))
        }
        if let map = raw["map_remote"] as? [String: Any] {
            guard let destination = map["destination"] as? String, !destination.isEmpty else {
                throw MCPError.invalidParams("map_remote requires a non-empty `destination`")
            }
            routes.append(.mapRemote(MapRemoteAction(
                destination: destination,
                excludePattern: (map["exclude"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                keepHostHeader: (map["keep_host_header"] as? Bool) ?? false
            )))
        }
        if let map = raw["map_local"] as? [String: Any] {
            guard let path = map["path"] as? String, !path.isEmpty else {
                throw MCPError.invalidParams("map_local requires a non-empty `path`")
            }
            routes.append(.mapLocal(MapLocalAction(
                path: path,
                statusCode: (map["status_code"] as? Int) ?? 200,
                contentType: map["content_type"] as? String
            )))
        }
        guard routes.count <= 1 else {
            throw MCPError.invalidParams("set at most one of block/mock_response/map_remote/map_local")
        }
        actions.route = routes.first ?? .passthrough

        if let rewrite = raw["rewrite_request"] as? [String: Any] {
            actions.rewriteRequest = RequestRewriteAction(
                method: rewrite["method"] as? String,
                setHeaders: headerPairs(rewrite["set_headers"]),
                removeHeaders: (rewrite["remove_headers"] as? [String]) ?? [],
                bodyText: rewrite["body"] as? String
            )
        }
        if let rewrite = raw["rewrite_response"] as? [String: Any] {
            actions.rewriteResponse = ResponseRewriteAction(
                statusCode: rewrite["status_code"] as? Int,
                setHeaders: headerPairs(rewrite["set_headers"]),
                removeHeaders: (rewrite["remove_headers"] as? [String]) ?? [],
                bodyText: rewrite["body"] as? String
            )
        }
        actions.requestSubstitutions = try substitutions(raw["request_substitutions"], key: "request_substitutions")
        actions.responseSubstitutions = try substitutions(raw["response_substitutions"], key: "response_substitutions")
        actions.delayMilliseconds = raw["delay_ms"] as? Int
        return actions
    }

    /// Parse substitutions strictly: a malformed item (bad `field` enum, missing
    /// `match`) is an error, not a silently-dropped row — otherwise the AI is told
    /// the rule was created while the store holds less than it sent.
    private static func substitutions(_ raw: Any?, key: String) throws -> [SubstitutionRule] {
        guard let raw else { return [] }
        guard let array = raw as? [[String: Any]] else {
            throw MCPError.invalidParams("\(key) must be an array of {field, match, ...} objects")
        }
        return try array.map { item in
            guard let fieldRaw = item["field"] as? String else {
                throw MCPError.invalidParams("\(key): each item needs a `field`")
            }
            guard let field = SubstitutionRule.Field(rawValue: fieldRaw) else {
                throw MCPError.invalidParams("\(key): invalid field \"\(fieldRaw)\" (url/header/body)")
            }
            guard let match = item["match"] as? String else {
                throw MCPError.invalidParams("\(key): each item needs a `match` string")
            }
            return SubstitutionRule(
                field: field,
                match: match,
                replacement: (item["replacement"] as? String) ?? "",
                isRegex: (item["is_regex"] as? Bool) ?? false,
                caseSensitive: (item["case_sensitive"] as? Bool) ?? false
            )
        }
    }

    private static func headerPairs(_ raw: Any?) -> [HeaderPair] {
        guard let dict = raw as? [String: Any] else { return [] }
        return dict.map { HeaderPair(name: $0.key, value: String(describing: $0.value)) }
    }

    private static func rule(_ rule: TrafficRule, truncateBodies: Bool) -> [String: Any] {
        var out: [String: Any] = [
            "id": rule.id.uuidString,
            "name": rule.name,
            "enabled": rule.isEnabled,
            "match": {
                var match: [String: Any] = ["urlPattern": rule.match.urlPattern]
                if rule.match.isRegex { match["isRegex"] = true }
                if rule.match.isExact { match["isExact"] = true }
                if let hostPattern = rule.match.hostPattern, !hostPattern.isEmpty { match["hostPattern"] = hostPattern }
                if let query = rule.match.query, !query.isEmpty { match["query"] = query }
                if let sourceApp = rule.match.sourceApp, !sourceApp.isEmpty { match["sourceApp"] = sourceApp }
                if let deviceIP = rule.match.deviceIP, !deviceIP.isEmpty { match["deviceIP"] = deviceIP }
                if !rule.match.methods.isEmpty { match["methods"] = rule.match.methods }
                return match
            }(),
            "createdAt": Self.iso8601.string(from: rule.createdAt),
        ]
        if let comment = rule.comment { out["comment"] = comment }
        if let group = rule.group { out["group"] = group }

        var actions: [String: Any] = [:]
        let a = rule.actions
        switch a.route {
        case .passthrough:
            break
        case .block:
            actions["block"] = true
        case let .mock(mock):
            var mockOut: [String: Any] = ["statusCode": mock.statusCode]
            if !mock.headers.isEmpty { mockOut["headers"] = headerDict(mock.headers) }
            if let contentType = mock.contentType { mockOut["contentType"] = contentType }
            addBody(mock.bodyText, to: &mockOut, truncate: truncateBodies)
            if let base64 = mock.bodyBase64 {
                mockOut["bodyBase64"] = truncateBodies && base64.count > 256
                    ? String(base64.prefix(256)) + "…(\(base64.count) base64 chars)"
                    : base64
            }
            actions["mockResponse"] = mockOut
        case let .mapRemote(map):
            var mapOut: [String: Any] = ["destination": map.destination]
            if let exclude = map.excludePattern { mapOut["exclude"] = exclude }
            if map.keepHostHeader { mapOut["keepHostHeader"] = true }
            actions["mapRemote"] = mapOut
        case let .mapLocal(map):
            var mapOut: [String: Any] = ["path": map.path, "statusCode": map.statusCode]
            if let contentType = map.contentType { mapOut["contentType"] = contentType }
            actions["mapLocal"] = mapOut
        }
        if let rewrite = a.rewriteRequest, !rewrite.isEmpty {
            var rw: [String: Any] = [:]
            if let method = rewrite.method { rw["method"] = method }
            if !rewrite.setHeaders.isEmpty { rw["setHeaders"] = headerDict(rewrite.setHeaders) }
            if !rewrite.removeHeaders.isEmpty { rw["removeHeaders"] = rewrite.removeHeaders }
            addBody(rewrite.bodyText, to: &rw, truncate: truncateBodies)
            actions["rewriteRequest"] = rw
        }
        if let rewrite = a.rewriteResponse, !rewrite.isEmpty {
            var rw: [String: Any] = [:]
            if let status = rewrite.statusCode { rw["statusCode"] = status }
            if !rewrite.setHeaders.isEmpty { rw["setHeaders"] = headerDict(rewrite.setHeaders) }
            if !rewrite.removeHeaders.isEmpty { rw["removeHeaders"] = rewrite.removeHeaders }
            addBody(rewrite.bodyText, to: &rw, truncate: truncateBodies)
            actions["rewriteResponse"] = rw
        }
        if !a.activeRequestSubstitutions.isEmpty {
            actions["requestSubstitutions"] = a.activeRequestSubstitutions.map(substitutionDict)
        }
        if !a.activeResponseSubstitutions.isEmpty {
            actions["responseSubstitutions"] = a.activeResponseSubstitutions.map(substitutionDict)
        }
        if let delay = a.delayMilliseconds { actions["delayMs"] = delay }
        out["actions"] = actions
        return out
    }

    private static func substitutionDict(_ sub: SubstitutionRule) -> [String: Any] {
        var out: [String: Any] = ["field": sub.field.rawValue, "match": sub.match, "replacement": sub.replacement]
        if sub.isRegex { out["isRegex"] = true }
        if sub.caseSensitive { out["caseSensitive"] = true }
        return out
    }

    // MARK: - Breakpoint rendering

    private static func matchDict(_ match: RuleMatch) -> [String: Any] {
        var out: [String: Any] = ["urlPattern": match.urlPattern]
        if match.isRegex { out["isRegex"] = true }
        if match.isExact { out["isExact"] = true }
        if let hostPattern = match.hostPattern, !hostPattern.isEmpty { out["hostPattern"] = hostPattern }
        if let query = match.query, !query.isEmpty { out["query"] = query }
        if let sourceApp = match.sourceApp, !sourceApp.isEmpty { out["sourceApp"] = sourceApp }
        if let deviceIP = match.deviceIP, !deviceIP.isEmpty { out["deviceIP"] = deviceIP }
        if !match.methods.isEmpty { out["methods"] = match.methods }
        return out
    }

    private static func breakpoint(_ bp: Breakpoint) -> [String: Any] {
        var out: [String: Any] = [
            "id": bp.id.uuidString,
            "match": matchDict(bp.match),
            "onRequest": bp.onRequest,
            "onResponse": bp.onResponse,
            "createdAt": iso8601.string(from: bp.createdAt),
        ]
        if let comment = bp.comment { out["comment"] = comment }
        return out
    }

    private static func pendingBreakpoint(_ pending: PendingBreakpoint) -> [String: Any] {
        var out: [String: Any] = [
            "id": pending.id.uuidString,
            "breakpointId": pending.breakpointID.uuidString,
            "phase": pending.phase.rawValue,
            "heldAt": iso8601.string(from: pending.heldAt),
            "request": [
                "method": pending.method,
                "url": pending.url,
                "headers": pending.requestHeaders.map { ["name": $0.name, "value": $0.value] },
                "body": bodyField(pending.requestBody),
            ],
        ]
        if pending.phase == .response {
            var response: [String: Any] = [
                "headers": (pending.responseHeaders ?? []).map { ["name": $0.name, "value": $0.value] },
                "body": bodyField(pending.responseBody),
            ]
            if let statusCode = pending.statusCode { response["status"] = statusCode }
            out["response"] = response
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
    private static func bodyField(_ data: Data?, offset: Int = 0, maxBytes: Int = defaultBodyBytes) -> Any {
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
    private static func utf8Text(_ window: Data, trimLeading: Bool, trimTrailing: Bool) -> String? {
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

    private static func headerDict(_ headers: [HeaderPair]) -> [String: String] {
        Dictionary(headers.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    /// Keep `list_rules` light: long bodies are cut to a preview + total length so
    /// a rule list with big JSON mocks doesn't flood the agent's context.
    private static func addBody(_ text: String?, to out: inout [String: Any], truncate: Bool) {
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

    private static func overrides(from arguments: [String: Any]) -> ReplayOverrides {
        var setHeaders: [HeaderPair]?
        if let raw = arguments["set_headers"] as? [String: Any] {
            setHeaders = raw.map { HeaderPair(name: $0.key, value: String(describing: $0.value)) }
        }
        let removeHeaders = arguments["remove_headers"] as? [String]
        let body: BodyOverride
        if let bodyString = arguments["body"] as? String {
            body = .replace(Data(bodyString.utf8))
        } else if (arguments["clear_body"] as? Bool) == true {
            body = .clear
        } else {
            body = .keep
        }
        return ReplayOverrides(
            method: arguments["method"] as? String,
            url: arguments["url"] as? String,
            setHeaders: setHeaders,
            removeHeaders: removeHeaders,
            body: body
        )
    }

    private func prettyJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return String(describing: value)
        }
        return string
    }
}
