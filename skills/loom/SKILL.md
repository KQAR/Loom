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
   When you are about to *trigger* the traffic (tap a button, run a command), use
   `wait_for_flow` instead of calling `get_recent_flows` in a loop: it blocks until
   a matching exchange lands and returns it.
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
| `get_proxy_status` | running state, listen address (`lanReachable`), captured flow count, recording state, and **`systemProxy`: `on` / `off` / `unavailable`** — whether this Mac's own traffic is actually routed through Loom. Check it first when a capture is empty: "nothing happened" and "nothing was pointed at the proxy" look identical otherwise |
| `list_devices` | devices that sent traffic (this Mac + LAN devices), typed from User-Agent, with per-device counts + last-seen |
| `get_recent_flows` | newest-first flow summaries (method, url, status, `startedAt`, flags). **Filter server-side** — `host` (glob ok), `method`, `url_contains`, `header_contains`, `body_contains`, `status`/`status_min`/`status_max` (`"5xx"` works), `only_errors`, `since_seconds`, `device_ip`, `source_app` — filters apply across the whole capture *before* `limit`, so don't pull a big list and scan it yourself. `captureTruncated: true` means a body (or the WS frame log) is only a prefix of what flowed |
| `wait_for_flow` | **block** until a flow matching those same filters is captured (default 20 s, max 60), then return it — the tool to use around "trigger the action, then look". Checks the stored capture first, so a match that already arrived comes back immediately. `until` picks how much to wait for: `completed` (default), `response` (status known, body may still stream — use for WebSocket/long downloads), `request` (first sighting). The default window is the last 10 s (so triggering the action *then* calling can't race); widen with `since_seconds`/`since`. A timeout is a normal result (`timedOut: true`) and costs nothing: the flow stays in the store, and retrying with `since` = the reply's `windowFrom` resumes with no gap |
| `get_stats` | aggregate instead of reading: per-bucket flow counts, error rates, TTFB/duration percentiles + the slowest exchanges *with ids*. `group_by`: `host` (default), `endpoint` (method + path, ids collapsed to `{id}`), `status`, `app`, `device`, `none`. Same filters as `get_recent_flows`. Use it for "which endpoint is slow", "what share of these calls fail", "who is chatty" — a percentile over one page of summaries isn't a percentile. `sizeUnknownFlows` on a bucket = its byte totals are a floor (those bodies have been evicted) |
| `get_flow_detail` | full headers + body for one flow id; adds `webSocket.messages` / `graphQL` blocks when present. Bodies are **bounded**: over `max_bytes` (default 16 KB) you get `{truncated, preview, bytes, offset, nextOffset}` — page with `body_offset: nextOffset`. A non-text body is `{binary, bytes}`, never `""`. WebSocket frames are capped by `ws_limit` (default 100, most recent) and flagged with `messagesTruncated` |
| `diff_flows` | structured diff of two flows by id (`base` + `compared`, or `base` alone to diff a replay vs its original); reports method/url, header add/remove/change, status, line-level body diff |
| `get_audit_log` | recent write actions taken through Loom (replay/rules/breakpoints/ssl-scope/har), newest-first, with tool name, arguments, outcome, timestamp; use to review what writes have been made (yours or a prior session's) |
| `get_certificate_status` | root-CA state: generated? trusted? fingerprint, expiry, exported path |
| `get_ssl_scope` | HTTPS interception on/off + include/exclude host globs |
| `list_rules` | master switch + all rules (long bodies truncated); pass `id` for one rule with full bodies |
| `list_pending` | armed breakpoints + exchanges held right now awaiting a `resume` (returns immediately with whatever is held) |
| `wait_for_pending` | **block** until a breakpoint holds an exchange (default 20 s, max 60; optional `breakpoint_id`), then return it — use this after arming, instead of polling `list_pending`. Anything already held comes back immediately |

### Write (the reason Loom exists — these change behavior; there is NO approval gate, they act directly)

| Tool | Purpose |
| --- | --- |
| `set_system_proxy` | route this Mac's HTTP/HTTPS traffic through Loom (`enabled`), or restore the previous settings. Machine-wide, may prompt for an admin password, and also blocks QUIC (UDP 443) so browsers fall back to TCP where a proxy can see them. Turn it off when done (Loom also restores on quit). A phone/other device doesn't need this — point that device at the proxy instead |
| `set_recording` | pause/resume recording (traffic keeps flowing; nothing new is stored) — use it to keep background noise out of a capture |
| `clear_flows` | discard every captured flow, in memory and on disk. Destructive and not undoable, and it empties the human's window too — prefer `get_recent_flows` with `since_seconds` unless you really need a clean slate |
| `replay_flow` | re-send a flow with `overrides` (method / url / set+remove headers / body) → a new flow linked via `replayedFrom`. `count` (max 50) re-sends it N times with `concurrency` (max 10) in flight — for "is this failure intermittent?" / "does it hold up in parallel?"; the reply becomes a batch summary (`succeeded`/`failed`/`statusClasses`/`ttfbMS` + per-attempt ids) and a failing attempt is reported, not thrown. Each attempt is a real request and obeys armed rules/breakpoints |
| `set_rule` | create (omit `id`) or update (`id`) a structured traffic rule — upsert (see below); on update, provided fields replace, incl. per-rule enable/disable + regroup |
| `delete_rule` | remove a rule by id |
| `set_rules_enabled` | master switch for the whole rule engine |
| `set_group_enabled` | enable/disable every rule in a group — scenario switching |
| `arm_breakpoint` | hold matching traffic mid-flight (request and/or response phase) for inspection/editing; match reuses the rule `match` schema |
| `disarm_breakpoint` | remove an armed breakpoint by id |
| `resume` | release a held exchange by its `pending_id`: apply edits (method / url / status_code / set+remove headers / body) and continue, or `abort` with a 502 |
| `set_ssl_scope` | turn HTTPS interception on/off + set include/exclude host globs |
| `export_ca_certificate` | write the root CA (PEM) to disk for trusting; returns the path |
| `export_har` | export captured flows to a HAR 1.2 file (host filter + limit); returns the path. **`redact: true`** scrubs credential headers + token query params (values become `<redacted>`, the header stays so a reader can tell scrubbed from absent) — it does **not** touch bodies or WebSocket frames, so a password in a login POST survives it. **`redact_bodies: true`** blanks those too, keeping their sizes; `redact_headers` adds names. If the file is leaving the machine, pass both |
| `import_har` | load a HAR file into the capture as flows (`path`, optional `label`) so an exchange recorded elsewhere can be read, diffed and **replayed** like live traffic. Imported flows are labelled `importedFrom` and get fresh `ids`; unusable entries are reported in `skipped`/`skippedReasons` |

### Rules (`set_rule`) — the shape

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
  `arm_breakpoint` with `on_request` (and/or `on_response`) matching the URL, trigger
  the client, then `wait_for_pending` — it returns the held exchange as soon as it
  lands (no polling). Inspect it and `resume` with edits (or `abort`). The exchange
  is holding a live client connection while you think, and an unattended hold
  auto-continues after a timeout, so decide and resume promptly. `disarm_breakpoint`
  when done.
- **"Does it fail every time, or one in ten?"** → `replay_flow` with `count: 10`
  (add `concurrency` to test parallel behaviour). Read `statusClasses` and `failed`
  in the summary; each attempt has its own flow id for a closer look.
- **"Why is this screen slow / what's failing?"** → `get_stats` with
  `since_seconds` (and `group_by: endpoint` once you know the host). Read the error
  rate and the TTFB p95, then `get_flow_detail` on an id from `slowest` — don't page
  through summaries computing averages.
- **"Which request carried this order id / token?"** → `get_recent_flows` with
  `body_contains` (or `header_contains` for an auth token / trace header) instead of
  paging `get_flow_detail` over candidates. Narrow it with `host`/`since_seconds` —
  a body search reads through to the on-disk capture.
- **"Mock it for my app only, don't break my browser."** → put `source_app` (bundle
  id or name, from a flow's `sourceApp`) or `device_ip` (from `list_devices`) in the
  rule's `match`. Both also work on `arm_breakpoint`. Traffic Loom can't attribute to
  a client never matches a scoped rule, so a scope can't leak — and a replay inherits
  the origin of the flow it re-sends, so a scoped rule still applies on replay.
- **"Point this API at staging."** → `set_rule` map-remote (set
  `keepHostHeader` only if the upstream needs the original Host). Group related
  redirects so `set_group_enabled` flips the whole scenario at once.
- **"Capture HTTPS for api.example.com."** → `set_ssl_scope` enabled with an
  include glob; if bodies stay empty, `get_certificate_status` — the CA likely
  isn't trusted. `export_ca_certificate` returns a PEM; trusting it is a manual
  admin step on the client.
- **"Give me a HAR of today's traffic to that host."** → `export_har` with a host
  filter; return the path. If it's going into a ticket or a chat, pass **both**
  `redact: true` and `redact_bodies: true` — headers alone leave every payload
  intact — and tell the human what was scrubbed. The tool says so in its result
  when bodies were kept; don't call a file redacted when it isn't.
- **"Here's a HAR from a colleague / CI — why did that request fail?"** →
  `import_har`, then work the flows exactly as if they were live: `get_flow_detail`,
  `diff_flows` against a local one, `replay_flow` to re-send it from here. They stay
  labelled `importedFrom`, so don't report them as traffic observed on this machine.

## Honest failure modes (report, don't fabricate)

- `loom` tools missing / connection refused on `127.0.0.1:9092` → **the Loom app
  isn't running or isn't installed**. Ask the user to install/launch it; don't
  guess at traffic.
- No flows / empty `get_recent_flows` → check `get_proxy_status`: if `systemProxy` is
  `off`, this Mac's traffic isn't routed through Loom (fix with `set_system_proxy`);
  otherwise nothing has been routed through the proxy
  yet (client not pointed at it, or recording paused). Say so.
- HTTPS flow is a blind tunnel / empty body → host out of SSL scope or CA not
  trusted (or legitimate cert pinning, e.g. Apple domains). Diagnose with
  `get_ssl_scope` + `get_certificate_status`; don't claim you saw the plaintext.
- A write tool acts immediately and globally — there is no confirmation prompt.
  When a rule would broadly alter traffic (e.g. a wide block glob), state what it
  will affect before creating it.

## Filing a Loom bug (public issue — scrub before you post)

First, **check it's actually a Loom bug.** These are known and documented; refiling
them is noise:

| What you see | What it is |
|---|---|
| An h2 upload > 65535 bytes hangs, ~1 in 100 | Upstream NIOHTTP2 defect, already tracked as #99 — decided to live with it |
| Apple / pinned domains fail under HTTPS interception | Certificate pinning working as designed, not a bug |
| HTTPS captured but bodies empty | CA not trusted on the client, or host out of SSL scope — check `get_certificate_status` / `get_ssl_scope` |
| `get_version` reports a version you just replaced | The app was rebuilt but not relaunched |
| Nothing captured at all | Nothing is routed through the proxy — check `get_proxy_status.systemProxy` |

**Then scrub.** By the time you decide to file, your context is full of the user's
real traffic — and the instinct that makes a *good* bug report (paste the exact
failing request) is exactly the wrong one here. A GitHub issue is public, indexed,
and effectively permanent; a deleted issue was still readable.

**Never put these in an issue**, in prose, in a code block, or in an attachment:

- Real hostnames or domains — including the user's employer, client, product,
  project, or internal service names, and anything recognisable in a bundle id
- URL paths and query strings that carry identifiers (order / account / user /
  session / trace ids)
- Request or response bodies, verbatim or excerpted
- `Authorization`, `Cookie`, `Set-Cookie`, API keys, JWTs, signatures — redacted
  or not, don't include the value or its shape
- Emails, phone numbers, names, device names, LAN IPs, `/Users/<name>/…` paths
- **A HAR file.** `export_har(redact: true)` scrubs credential headers and token
  query params — and nothing else: bodies and WebSocket frames come through
  verbatim unless you also pass `redact_bodies: true`. Even with both, hostnames,
  paths and timings survive, and that is business data. Keep it local; offer it to
  the maintainer privately only if they ask.

**Use placeholders consistently** so the report still reads: `api.example.com`,
`https://api.example.com/v1/items/{id}`, `<redacted-token>`, `AppUnderTest`,
`/Users/<user>/…`. Replace the *same* real value with the *same* placeholder.

**Reproduce on a neutral endpoint before filing.** If the failure survives against
`httpbin.org` / `example.com` / a throwaway local server, the report needs none of
the user's traffic and the maintainer can act on it immediately. If it genuinely
only reproduces against the real host, describe the *shape* — method, status,
approximate body size, content type, h1 vs h2, chunked vs fixed-length, TLS on/off
— never the identity.

**Keep what is actually diagnostic:** Loom version (`get_version`), macOS version,
proxy status, whether HTTPS interception was on (say "3 hosts in scope", not which
hosts), rules/breakpoints armed at the time (kind of rule, not the URLs), the exact
error text Loom itself emitted, and relevant lines from
`log stream --predicate 'subsystem == "com.loom"'` — scrubbed the same way.

**Show the human the full rendered issue and get explicit approval before creating
it.** Publishing is outward-facing and hard to take back; the user is the only one
who knows whether a name is sensitive. Then:

```bash
gh issue create --repo KQAR/Loom --title "…" --body "…" --label bug
```

Say plainly what you redacted ("host names replaced with `api.example.com`, body
omitted") so the maintainer knows the gaps are deliberate and can ask for more
through a private channel.
