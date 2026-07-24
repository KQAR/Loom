---
name: loom
description: >-
  Drive Loom — an AI-operable HTTP/HTTPS debugging proxy for macOS — over MCP to
  inspect and MODIFY live network traffic. Use when the task involves captured
  requests/responses on this Mac (or a LAN device routed through Loom) and you
  need to: list recent flows, read full headers/body of a request, replay a
  request with tweaks (method/url/headers/body), mock or map or rewrite or block
  or delay traffic with rules, switch scenarios via rule groups, turn HTTPS
  interception on/off per host, export the root CA, or export captured flows to
  HAR. Loom's differentiator vs a read-only proxy is its WRITE actions (replay,
  rules) — the agent closes the capture → modify → replay → diff loop.
  Triggers: "what requests did the app make", "replay that request without the
  auth header", "mock this endpoint to return 500", "map this API to staging",
  "block analytics calls", "why is this response failing", "capture my phone's
  traffic", "export the traffic as HAR", "intercept HTTPS for api.example.com".
---

# Loom — AI-operable HTTP/HTTPS debugging proxy (over MCP)

Loom captures HTTP/HTTPS traffic like Charles/Proxyman, but its primary operator
is **you, the agent, over MCP** — and the MCP surface exposes **write actions**
(replay, rules, breakpoints), not just read queries. You close the debugging
loop with no GUI; the human supervises from the menu-bar panel.

The MCP tools are hosted by the **running Loom app**, which serves the MCP
endpoint over HTTP on `127.0.0.1:9092`. This plugin's `loom` MCP server just
points Claude at that URL — it does **not** launch or build anything. All state
and logic live in the app.

## Prerequisites (check, don't assume)

- **The Loom app must be running** — it owns the MCP server (HTTP on
  `127.0.0.1:9092`); Claude only connects. If the `loom` MCP tools are missing,
  fail to connect, or `get_version` / `get_proxy_status` errors, **the Loom app
  isn't running (or isn't installed)**. Do not invent data — tell the user:
  *"Loom's MCP server isn't reachable. Install Loom (https://github.com/KQAR/Loom)
  if you don't have it, then launch the Loom app (menu-bar icon) and retry."*
  Confirm readiness with **`get_version`** / **`get_proxy_status`**.
- **Traffic only appears if a client routes through the proxy.** Loom listens on
  `127.0.0.1:9090` by default. Either the client uses it explicitly
  (`curl -x http://127.0.0.1:9090 …`) or the human enabled the macOS system
  proxy from the panel. A phone on the same Wi-Fi can be pointed at the Mac's LAN
  IP:9090 (see the panel's phone QR). Use **`list_devices`** to see who's sending.
- **HTTPS needs interception scope + a trusted CA.** Plain HTTP is captured out
  of the box. For HTTPS, SSL interception must be **on** and the host **in scope**
  (`get_ssl_scope` / `set_ssl_scope`), AND Loom's root CA must be trusted by the
  client. If HTTPS bodies are empty or the flow shows a blind tunnel, the CA
  isn't trusted or the host is out of scope — say so. Apple domains legitimately
  fail (cert pinning); that's expected, not a bug.

## The debugging loop

Loom is built for one cycle — do this, don't just read:

1. **Capture** — `get_recent_flows` to see what happened; `get_flow_detail` for
   the full exchange (headers, body, timing, WebSocket frames, GraphQL block).
2. **Modify + Replay** — `replay_flow` with `overrides` to re-send one flow with
   a changed method/URL/headers/body. The result is a *new* flow linked via
   `replayedFrom`.
3. **Automate** — when a change should apply to *future* traffic, express it as a
   rule (`set_rule`): mock, map-remote, map-local, rewrite, find/replace,
   block, or delay. Toggle sets of them with groups for scenario switching.
4. **Diff** — `diff_flows` gives a structured comparison of the original vs the
   replayed/ruled flow (method/url, header add/remove/change, status, line-level
   body diff). Pass just `base` = the replayed flow's id to diff it against its
   `replayedFrom` original in one call. Repeat 2–4 until the response is right.

## Tool reference

### Read (safe, no side effects)

| Tool | Purpose |
| --- | --- |
| `get_version` | app + MCP protocol version — a cheap readiness ping |
| `get_proxy_status` | running state, bind port, captured flow count |
| `list_devices` | devices that sent traffic (this Mac + LAN devices), typed from User-Agent, with per-device counts + last-seen |
| `get_recent_flows` | newest-first flow summaries (method, url, status, host, flags) |
| `get_flow_detail` | full headers + body for one flow id; adds `webSocket.messages` / `graphQL` blocks when present |
| `diff_flows` | structured diff of two flows by id (`base` + `compared`, or `base` alone to diff a replay vs its original); reports method/url, header add/remove/change, status, line-level body diff |
| `get_audit_log` | recent write actions taken through Loom (replay/rules/breakpoints/ssl-scope/har), newest-first, with tool name, arguments, outcome, timestamp; use to review what writes have been made (yours or a prior session's) |
| `get_certificate_status` | root-CA state: generated? trusted? fingerprint, expiry, exported path |
| `get_ssl_scope` | HTTPS interception on/off + include/exclude host globs |
| `list_rules` | master switch + all rules (long bodies truncated); pass `id` for one rule with full bodies |
| `list_pending` | armed breakpoints + exchanges held right now awaiting a `resume` (poll this — there is no server push) |

### Write (the reason Loom exists — these change behavior; there is NO approval gate, they act directly)

| Tool | Purpose |
| --- | --- |
| `replay_flow` | re-send a flow with `overrides` (method / url / set+remove headers / body) → a new flow linked via `replayedFrom` |
| `set_rule` | create (omit `id`) or update (`id`) a structured traffic rule — upsert (see below); on update, provided fields replace, incl. per-rule enable/disable + regroup |
| `delete_rule` | remove a rule by id |
| `set_rules_enabled` | master switch for the whole rule engine |
| `set_group_enabled` | enable/disable every rule in a group — scenario switching |
| `arm_breakpoint` | hold matching traffic mid-flight (request and/or response phase) for inspection/editing; match reuses the rule `match` schema |
| `disarm_breakpoint` | remove an armed breakpoint by id |
| `resume` | release a held exchange by its `pending_id`: apply edits (method / url / status_code / set+remove headers / body) and continue, or `abort` with a 502 |
| `set_ssl_scope` | turn HTTPS interception on/off + set include/exclude host globs |
| `export_ca_certificate` | write the root CA (PEM) to disk for trusting; returns the path |
| `export_har` | export captured flows to a HAR 1.2 file (host filter + limit); returns the path |

### Rules (`set_rule`) — the shape

A rule is a **structured** match + action (no text DSL). Match on a URL
glob-or-regex + HTTP methods; then one action:

- **mock** — return a canned status/headers/body without hitting the network.
- **map remote** — redirect to another origin (`+exclude`/`keepHostHeader`).
- **map local** — serve a local file.
- **rewrite** — modify the request and/or response headers/body.
- **find/replace** — `request_substitutions` / `response_substitutions` text swaps.
- **block** — fail the request.
- **delay** — add latency.
- optional `group` label for batch enable/disable (scenario switching).

## Common workflows

- **"What did the app just call?"** → `get_recent_flows`, then `get_flow_detail`
  on the interesting id. Group/attribute with `list_devices` when multiple
  clients are involved.
- **"Replay without the auth header / with a different body."** → `replay_flow`
  with `overrides` removing `Authorization` (or setting a new body). Then call
  `diff_flows` with `base` = the new flow's id to see exactly what changed vs the
  original it was replayed from.
- **"Make this endpoint return 500 / a fixed payload."** → `set_rule` with a
  mock action matching the URL. Verify by re-triggering the client and reading
  the newest flow (it will carry the rule in `appliedRules`).
- **"Pause this request so I can tamper with it before it goes out."** →
  `arm_breakpoint` with `on_request` (and/or `on_response`) matching the URL. Then
  **poll `list_pending`** until the exchange shows up, inspect it, and `resume`
  with edits (or `abort`). There is no push — you must poll. An unattended hold
  auto-continues after a timeout, so don't arm one and walk away. `disarm_breakpoint`
  when done.
- **"Point this API at staging."** → `set_rule` map-remote (set
  `keepHostHeader` only if the upstream needs the original Host). Group related
  redirects so `set_group_enabled` flips the whole scenario at once.
- **"Capture HTTPS for api.example.com."** → `set_ssl_scope` enabled with an
  include glob; if bodies stay empty, `get_certificate_status` — the CA likely
  isn't trusted. `export_ca_certificate` returns a PEM; trusting it is a manual
  admin step on the client.
- **"Give me a HAR of today's traffic to that host."** → `export_har` with a host
  filter; return the path.

## Honest failure modes (report, don't fabricate)

- `loom` tools missing / connection refused on `127.0.0.1:9092` → **the Loom app
  isn't running or isn't installed**. Ask the user to install/launch it; don't
  guess at traffic.
- No flows / empty `get_recent_flows` → nothing has been routed through the proxy
  yet (client not pointed at it, or recording paused). Say so.
- HTTPS flow is a blind tunnel / empty body → host out of SSL scope or CA not
  trusted (or legitimate cert pinning, e.g. Apple domains). Diagnose with
  `get_ssl_scope` + `get_certificate_status`; don't claim you saw the plaintext.
- A write tool acts immediately and globally — there is no confirmation prompt.
  When a rule would broadly alter traffic (e.g. a wide block glob), state what it
  will affect before creating it.
