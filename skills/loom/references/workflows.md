# Loom — workflows and failure modes

Recipes per task, then what it means when a capture doesn't look the way you
expected. Each tool's own description (from `tools/list`) is authoritative for
arguments; this file is about sequence and interpretation.

## Common workflows

- **"What did the app just call?"** → `get_recent_flows`, then `get_flow_detail`
  on the interesting id. Group/attribute with `list_devices` when multiple
  clients are involved.
- **"Replay without the auth header / with a different body."** → `replay_flow`
  with `overrides` removing `Authorization` (or setting a new body). Then call
  `diff_flows` with `base` = the new flow's id to see exactly what changed vs the
  original it was replayed from.
- **"Make this endpoint return 500 / a fixed payload."** → `set_rule` with a
  mock action matching the URL. Check `effective` in the reply — the rules master
  switch being off silently neutralises every rule. Verify by re-triggering the
  client and reading the newest flow (it carries the rule in `appliedRules`).
- **"Pause this request so I can tamper with it before it goes out."** →
  `arm_breakpoint` with `on_request` (and/or `on_response`) matching the URL,
  trigger the client, then `wait_for_pending` — it returns the held exchange as
  soon as it lands (no polling). Inspect it and `resume` with edits (or `abort`).
  The exchange is holding a live client connection while you think, and an
  unattended hold auto-continues after a timeout, so decide and resume promptly.
  `disarm_breakpoint` when done.
- **"Does it fail every time, or one in ten?"** → `replay_flow` with `count: 10`
  (add `concurrency` to test parallel behaviour). Read `statusClasses` and
  `failed` in the summary; each attempt has its own flow id for a closer look.
- **"Why is this screen slow / what's failing?"** → `get_stats` with
  `since_seconds` (and `group_by: endpoint` once you know the host). Read the
  error rate and the TTFB p95 — high TTFB is server think-time, high receive is
  payload transfer — then `get_flow_detail` on an id from `slowest`. Don't page
  through summaries computing averages.
  On that one flow, read `transport` before blaming the server: a
  `connectionReused: false` exchange also paid the connection's opening cost, and
  `transport.setup` splits it into `dnsMS` / `tcpMS` / `tlsHandshakeMS` — TTFB
  folds all three into what looks like think-time, and a slow DNS answer, a slow
  connect and a slow handshake are three different bugs. Compare it with a
  neighbouring flow to the same host that reused the socket (no `setup`, and
  `connectionReused: true`): if that one is fast, the endpoint isn't slow, the
  first connection was. `responseEncodedBodyBytes` is what actually crossed the
  wire (bodies are reported decompressed), which is the reading for "is this
  slow because it's big". An absent field means unmeasured, never zero.
- **"Which request carried this order id / token?"** → `get_recent_flows` with
  `body_contains` (or `header_contains` for an auth token / trace header) instead
  of paging `get_flow_detail` over candidates. Narrow it with
  `host`/`since_seconds` — a body search reads through to the on-disk capture.
- **"Mock it for my app only, don't break my browser."** → put `source_app`
  (bundle id or name, from a flow's `sourceApp`) or `device_ip` (from
  `list_devices`) in the rule's `match`. Both also work on `arm_breakpoint`.
  Traffic Loom can't attribute to a client never matches a scoped rule, so a
  scope can't leak — and a replay inherits the origin of the flow it re-sends, so
  a scoped rule still applies on replay. A **phone's** app is scopeable too, but
  read `sourceApp.attribution` first: `process` is a fact about the socket (a
  local app, resolved by pid), `userAgent` is what the client claimed about
  itself, so an app-scoped rule on a LAN device is only as trustworthy as that
  header. When it must not be guessed at, scope by `device_ip` instead.
- **"Point this API at staging."** → `set_rule` map-remote (set `keepHostHeader`
  only if the upstream needs the original Host). Group related redirects so
  `set_group_enabled` flips the whole scenario at once.
- **"Capture HTTPS for api.example.com."** → `intercept_host` (one call: it adds
  the host, turns interception on if it was off, and reports `effective: false`
  when a wildcard `exclude` still shadows it). Use `set_ssl_scope` when you want a
  glob or are replacing the lists wholesale. The scope is a **whitelist and starts
  empty**, so this is a routine first step rather than a repair. Only new
  connections are affected, so have the client re-run. If bodies stay empty after that,
  `get_certificate_status` — the CA likely isn't trusted.
  `export_ca_certificate` returns a PEM; trusting it is a manual admin step on the
  client.
- **"The app made requests but Loom shows nothing for host X."** → `get_ssl_scope`
  first, not `get_recent_flows` again: an unread relay records no flow at all, so
  `tunneledHosts` is the only place the fact exists. `notInScope` is the **ordinary**
  state of a host nobody named — the scope is a whitelist — and it, `excluded`
  (someone carved the host out of a glob) and `interceptionDisabled` are all one
  `intercept_host` away; `notTLSOrHTTP` (h2c, SSH, SMTP, a server-first
  protocol), `noCertificateAuthority` and `leafMintFailed` are not. Two more mean
  the request never happened at all — the client is broken with Loom in the path,
  not merely unread: `clientHandshakeFailed` (it refused Loom's leaf and hung up
  before sending anything — it carries its own trust store or pins the host; the
  fix is to leave the host out of `include`, or to trust Loom's CA in *that*
  client) and
  `protocolError` (Loom's HTTP/2 codec could not read the connection and closed
  it — `detail` carries the codec's own error, and it is worth filing). Say which
  it is rather than adding globs and hoping.
- **"Stop decrypting this host / it broke with Loom on."** → remove it from
  `include` via `set_ssl_scope` (pass the existing lists minus that host — the call
  replaces them). Only add it to `exclude` when a glob you left in `include`
  (`*`, `*.corp`) still covers it. Under an empty whitelist this rarely comes up at
  all: a client carrying its own trust store (a JVM, Python, Go — a Gradle build or
  a `pip install`) and a pinned host both keep working until someone decrypts them,
  and the failure, when it happens, surfaces at the client as a certificate error. Loom does see the refusal, though — that host
  appears in `get_ssl_scope`'s `tunneledHosts` as `clientHandshakeFailed` with the
  handshake error in `detail`, so you can name the host instead of asking the user
  which one broke.
- **"Give me a HAR of today's traffic to that host."** → `export_har` with a host
  filter; return the path. If it's going into a ticket or a chat, pass **both**
  `redact: true` and `redact_bodies: true` — headers alone leave every payload
  intact — and tell the human what was scrubbed. The tool says so in its result
  when bodies were kept; don't call a file redacted when it isn't.
- **"Here's a HAR from a colleague / CI — why did that request fail?"** →
  `import_har`, then work the flows exactly as if they were live:
  `get_flow_detail`, `diff_flows` against a local one, `replay_flow` to re-send
  it from here. They stay labelled `importedFrom`, so don't report them as
  traffic observed on this machine.

- **"My dev server proxies `/api` to a backend and Loom captures nothing"** →
  the browser→dev-server hop is loopback, which browsers hard-code to bypass a
  proxy, and the dev-server→backend hop may ignore proxy settings entirely (Node's
  global `fetch`/undici does; axios and Python/Go clients read `HTTP_PROXY` and
  need nothing). For the forwarding hop, `create_reverse_proxy(upstream:
  "https://api.example.com")` and have the user point the dev server's proxy target
  at the `localURL` it returns — one line of config, no source patch, no CA trust
  on that hop (it is plain HTTP). Captured flows carry the **upstream** URL, so
  rules and breakpoints match them normally. Close it with `delete_reverse_proxy`,
  and say that a config still naming the port will then get connection refused.

## Honest failure modes (report, don't fabricate)

- `loom` tools missing / connection refused on `127.0.0.1:9092` → **the Loom app
  isn't running or isn't installed**. Ask the user to install/launch it; don't
  guess at traffic.
- No flows / empty `get_recent_flows` → check `get_proxy_status`:
  - `systemProxy: "off"` → this Mac's traffic isn't routed through Loom (fix with
    `set_system_proxy`);
  - `systemProxy: "other"` → **another proxy app holds the setting**
    (`systemProxyPointsAt` names it). Tell the user to quit it rather than calling
    `set_system_proxy`: taking the setting works, but Loom does not put the other
    app's configuration back when it releases it, so that is the user's call;
  - `refusedConnections` / `recentRefusals` present → a client *did* reach Loom
    and was turned away (a SOCKS4 client, an HTTP request sent to the SOCKS
    port). That looks identical to a client that never ran; this is the
    difference;
  - the client may not honour HTTP proxy settings at all (a Go/Rust/Node CLI that
    reads only `ALL_PROXY`, a tool whose only field is a SOCKS one). Point it at
    the **SOCKS5 listener** instead — `get_proxy_status.socksPort` (normally one
    above the HTTP port, e.g. `ALL_PROXY=socks5://127.0.0.1:9091`). It captures
    HTTP and MITM-able TLS the same way, and relays anything else untouched;
  - `reverseProxies` present with `listening: false` → that endpoint's port is not
    bound (its `error` says why, usually taken by the very dev server it was made
    for). A client pointed at it gets connection refused, which looks like Loom is
    down — recreate it on a free port;
  - the client may ignore proxy configuration altogether (Node's `fetch`/undici
    does, whatever the environment says). Neither port helps there: open a
    `create_reverse_proxy` endpoint and re-point the client at it;
  - `lanReachable: false` (i.e. `listenHost` is `127.0.0.1`) and the client is a
    **phone or another device** → it cannot reach Loom at all, however correctly it
    is configured: the connection is refused before Loom is involved, so there is
    nothing to find. The human turns LAN device connection on from the panel's
    Device tile;
  - `isRecording: false` → the proxy is still forwarding and decrypting, it is just
    not *storing*. Nothing will appear until `set_recording(true)`, and a prior
    session (yours or a human's) may have paused it;
  - otherwise nothing has been routed through the proxy yet — the client is not
    pointed at it. Say so.
- Only a `CONNECT` entry for a host → it was passed through (nobody named it — the
  common case, since the scope is a whitelist — or Loom can't read it). The CONNECT
  row is the connection, not the request: no headers, no body. `intercept_host`
  then re-run the client. A host Loom cannot read at any setting records no flow
  whatsoever, not even that. `get_ssl_scope`'s `tunneledHosts` is the only surface holding this fact;
  check it before reporting that the client made no requests.
- HTTPS flow is a blind tunnel / empty body → host out of SSL scope or CA not
  trusted (or legitimate cert pinning, e.g. Apple domains). Diagnose with
  `get_ssl_scope` + `get_certificate_status`; don't claim you saw the plaintext.
- The flow **failed** on an `https://` host with a TLS/handshake error, and the host
  is in scope with a trusted CA → the origin may require a **client certificate**
  (mutual TLS: common on internal and partner APIs). Read the flow's `error` first —
  it names the host and whether Loom presented an identity or had none — then check
  `list_client_certificates` (an expired or unreadable identity fails identically to
  a missing one) and install one with `set_client_certificate` if the user has the
  `.p12`. Ask them for it; don't go hunting through their keychain or disk. The
  error reports what Loom did, not what the server required: Loom cannot tell a
  client-certificate requirement from any other handshake failure, so don't restate
  it as one.
- A write tool acts immediately and globally — there is no confirmation prompt.
  When a rule would broadly alter traffic (e.g. a wide block glob), state what it
  will affect before creating it.
