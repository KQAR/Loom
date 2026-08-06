---
name: loom
description: >-
  Drive Loom — an AI-operable HTTP/HTTPS debugging proxy for macOS — over MCP to
  inspect and MODIFY live traffic captured on this Mac or a LAN device: search
  flows, read headers/bodies, replay with overrides, diff, aggregate timings,
  apply rules (mock/map/rewrite/block/delay, grouped for scenario switching),
  hold a request at a breakpoint and edit it in flight, per-host HTTPS
  interception, mutual-TLS client certificates, root-CA export, HAR in and out.
  The WRITE actions are the point — the agent closes capture → modify → replay →
  diff. Triggers: "what did the app just call", "replay that without the auth
  header", "mock this endpoint to return 500", "map this API to staging", "block
  analytics calls", "pause this request before it goes out", "why is this
  endpoint slow", "capture my phone's traffic", "export the traffic as HAR",
  "intercept HTTPS for api.example.com".
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

**Each tool's own description is the authoritative reference for its arguments
and edge cases** (it arrives with `tools/list`). This file is the map: what to
reach for, in what order, and what to do when the answer is "nothing captured".

## Prerequisites (check, don't assume)

- **The Loom app must be running** — it owns the MCP server; Claude only
  connects. If the `loom` tools are missing, fail to connect, or `get_version` /
  `get_proxy_status` errors, **the app isn't running (or isn't installed)**. Do
  not invent data — tell the user: *"Loom's MCP server isn't reachable. Install
  Loom (https://github.com/KQAR/Loom) if you don't have it, then launch the Loom
  app (menu-bar icon) and retry."*
- **Check the plugin and the app are the same version, once per session.** They
  version independently: the tools you can call come from the *app*, their prose
  comes from whatever plugin version is installed — so a plugin newer than the app
  describes tools that aren't there, and an app newer than the plugin has tools
  this skill never mentions. No version is written down here on purpose (a copied
  number goes stale and then lies). Read it from the plugin's own manifest —
  `../../.claude-plugin/plugin.json` relative to this file, or
  `../../.cursor-plugin/plugin.json` under Cursor — take its `version`, and compare
  with `get_version`'s `appVersion`. If they differ, say so once: older app →
  *"update Loom (panel footer → Update); the plugin is <plugin>, the app is
  <app>, so some tools described here may be missing."*; newer app → *"run
  `/plugin update loom`; the app is <app> and the plugin is <plugin>, so newer
  tools aren't documented here."* Then carry on — a skew is a stale description,
  not a broken connection, and `tools/list` is always the truth about what exists.
  Don't repeat the notice, and don't block work on it.
- **Traffic only appears if a client routes through the proxy.** Loom listens on
  `127.0.0.1:9090` (HTTP) and `127.0.0.1:9091` (SOCKS5, for clients that only
  understand `ALL_PROXY` / a SOCKS field). Either the client is pointed there
  explicitly, or the human enabled the macOS system proxy; a phone on the same
  Wi-Fi uses the Mac's LAN IP (panel QR). `get_proxy_status` has the
  authoritative ports and routing state; `list_devices` shows who is sending.
- **HTTPS needs interception scope + a trusted CA.** Plain HTTP is captured out
  of the box. For HTTPS, interception must be **on** with the host **in scope**
  (`get_ssl_scope`), AND Loom's root CA trusted by the client. The scope decrypts
  everything by default, so a *missing* https:// host is usually one someone put in
  `exclude` — that is how a client carrying its own certificate store (a JVM,
  Python, Go) or a pinned host is kept working. A relayed connection records **no
  flow at all**, which looks exactly like a client that never ran;
  `get_ssl_scope`'s `tunneledHosts` is the only surface holding that fact. Read it
  before concluding nothing happened, then `intercept_host` and have the client
  re-run (an exchange already relayed is gone). Apple domains legitimately fail
  (cert pinning); expected, not a bug.

## The debugging loop

Loom is built for one cycle — do this, don't just read:

1. **Capture** — `get_recent_flows` to see what happened; `get_flow_detail` for
   the full exchange. When you are about to *trigger* the traffic (tap a button,
   run a command), use `wait_for_flow` instead of polling `get_recent_flows`.
2. **Modify + Replay** — `replay_flow` with `overrides` re-sends one flow with a
   changed method/URL/headers/body. The result is a *new* flow linked via
   `replayedFrom`.
3. **Automate** — when the change should apply to *future* traffic, express it as
   a rule (`set_rule`). Group them to flip whole scenarios.
4. **Diff** — `diff_flows` with `base` = the replayed flow's id compares it
   against its `replayedFrom` original in one call. Repeat 2–4.

## Tool index

Arguments and caveats live in each tool's own description; this is only what
each one is *for*.

### Read (no side effects)

| Tool | For |
| --- | --- |
| `get_version` | app + protocol version — cheap readiness ping |
| `get_proxy_status` | running state, ports, routing (`systemProxy`), refused connections — **first call when a capture is empty** |
| `list_devices` | who sent traffic (this Mac + LAN devices), with counts |
| `get_recent_flows` | newest-first summaries; filter server-side (host, method, url/header/body contains, status, since, app, device) |
| `wait_for_flow` | block until a matching flow lands — the "trigger, then look" tool |
| `get_stats` | aggregate: counts, error rates, TTFB/duration percentiles, slowest ids |
| `get_flow_detail` | full headers + body for one id (+ WebSocket / GraphQL blocks) |
| `diff_flows` | structured diff of two flows, or a replay vs its original |
| `get_audit_log` | write actions taken through Loom, yours or a prior session's |
| `get_certificate_status` | root-CA state: generated, trusted, fingerprint, expiry, path |
| `get_ssl_scope` | HTTPS interception on/off, host globs, **and the hosts Loom saw but did not decrypt** |
| `list_rules` | master switch + rules (pass `id` for full bodies) |
| `list_client_certificates` | mutual-TLS identities Loom presents; never the key or passphrase |
| `list_pending` | armed breakpoints + exchanges held right now |
| `wait_for_pending` | block until a breakpoint holds an exchange — use after arming |

### Write

**These act immediately and globally — there is no approval gate.** When one
would broadly alter traffic (a wide block glob, the system proxy), say what it
will affect before doing it. Every call is recorded in the audit trail.

| Tool | For |
| --- | --- |
| `set_system_proxy` | route this Mac through Loom, or turn the system proxy off (machine-wide, may prompt for admin, also blocks QUIC) |
| `set_recording` | pause/resume storing flows — keeps background noise out of a capture |
| `clear_flows` | discard the whole capture, memory and disk. Not undoable, and it empties the human's window too |
| `replay_flow` | re-send with overrides; `count`/`concurrency` for "is it intermittent?" |
| `set_rule` | create or update a structured rule (shape below) |
| `delete_rule` | remove one rule |
| `set_rules_enabled` | master switch for the rule engine |
| `set_group_enabled` | flip every rule in a group — scenario switching |
| `arm_breakpoint` | hold matching traffic mid-flight (request and/or response) |
| `disarm_breakpoint` | remove an armed breakpoint |
| `resume` | release a held exchange with edits, or `abort` with a 502 |
| `intercept_host` | start decrypting one host from `get_ssl_scope`'s `tunneledHosts` — usually one Loom is passing through |
| `set_ssl_scope` | HTTPS interception on/off + include/exclude host globs (wholesale; prefer `intercept_host` for one host) |
| `set_client_certificate` | add/replace a mutual-TLS identity (validated on set; scope it, `*` is almost never right) |
| `delete_client_certificate` | remove an identity — its hosts go back to failing the handshake |
| `export_ca_certificate` | write the root CA (PEM) to disk; returns the path |
| `export_har` | export flows to HAR 1.2. **Redaction is opt-in and partial** — see the export workflow before sending a file anywhere |
| `import_har` | load a HAR as flows, so an exchange recorded elsewhere can be read, diffed and replayed |

## Rules (`set_rule`) — the shape

A rule is a **structured** match + action (no text DSL). Match on a URL
glob-or-regex + HTTP methods, optionally narrowed by `host_pattern`, `query`, and
**who sent it** (`source_app` / `device_ip` — unattributed traffic never matches a
scoped rule); then one action:

- **mock** — return a canned status/headers/body without hitting the network.
- **map remote** — redirect to another origin (`+exclude`/`keepHostHeader`).
- **map local** — serve a local file.
- **rewrite** — modify the request and/or response headers/body.
- **find/replace** — `request_substitutions` / `response_substitutions` text swaps.
- **block** — fail the request.
- **delay** — add latency.
- optional `group` label for batch enable/disable (scenario switching).

## Going further

- **[references/workflows.md](references/workflows.md)** — the recipe per task
  ("what did the app call", mock an endpoint, tamper mid-flight, find the slow
  endpoint, scope a rule to one app, HAR in/out) and the **failure modes**: what
  an empty capture, a blind tunnel, or an unexplained TLS error actually mean.
  Read it when a capture doesn't look the way you expected.
- **[references/filing-a-bug.md](references/filing-a-bug.md)** — read **before**
  opening a GitHub issue against Loom: which symptoms are known non-bugs, and
  the scrubbing rules (your context is full of the user's real traffic, and an
  issue is public and permanent).
