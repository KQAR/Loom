# ROADMAP.md

Single source of truth for Loom's **positioning** and **iteration order**. When a scope or prioritization question arises, this doc wins over legacy assumptions in code or older notes. The user-facing shape of these phases is specified in [`INTERACTION.md`](INTERACTION.md); the visual system in [`DESIGN.md`](DESIGN.md).

## Positioning

Loom is **not** another Charles/Proxyman clone that adds a chat box. Human-first traffic inspection with an AI reading pane is table stakes — existing tools already ship that.

Loom is an **AI-operable debugging proxy**: a macOS status-bar app whose primary operator is an AI agent talking MCP, and whose human owner supervises from the menu bar. Its job is to let an agent **close the debugging loop without a GUI** — capture, inspect, *modify, replay, diff* — and to keep the human in control of the actions that touch real traffic.

Value hierarchy (higher beats lower when they conflict):

1. **AI can act, not just read.** The MCP surface exposes write actions (replay, rules, breakpoints), not only queries. This is the moat; read-only MCP is not.
2. **The human stays in control of risk.** The write-capable MCP control plane is loopback-only, and every write is recorded in a durable audit trail. An agent can debug freely; the owner can see everything it did and take over (stop / disable / disarm) at any time.
3. **Native and local.** 100% Swift/SwiftNIO, no Electron, no cloud. Captured traffic never leaves the machine; the MCP endpoint is loopback-only and token-authed.
4. **Throughput / breadth of protocols.** HTTP/2, WebSocket, GraphQL inspectors. Necessary reach, not the differentiator.

Guiding principle: **"the agent can finish the job" beats "the UI is prettier"**. Effort spent making a write action safe and scriptable is the product; effort spent on chrome the AI never sees is not.

## Target Loop (what "AI-operable" means)

The loop Loom must let an agent run end-to-end, entirely over MCP:

```
capture     traffic flows through the proxy into the store
   → inspect    get_recent_flows / get_flow_detail / filter
   → modify     replay_flow with overrides, or arm a breakpoint and edit in flight
   → observe    diff the replayed flow against the original
   → repeat     tighten the change until the response is right
```

M1 proves this loop on plain HTTP. Each later milestone widens what the agent can capture and act on, and hardens the human's control over it.

## Iteration Phases

### M1 — AI link (done)

- SwiftNIO HTTP proxy on `:9090`; CONNECT blind-tunnels HTTPS (uncaptured) so browsing survives.
- In-app MCP HTTP server + `loom-mcp` stdio bridge; handshake file hands the bridge a token+port.
- Read tools (`get_recent_flows`, `get_flow_detail`) **and one write tool** (`replay_flow` with method/url/header/body overrides).
- Menu-bar shell + Inspector window (flow list / detail / Replay).
- **Verified**: capture → list → replay-with-override → target sees the changed request, all via MCP, no GUI.

### M2 — HTTPS interception (interception done; a scoped privileged helper shipped in 0.0.17; system-domain CA trust still ruled out)

- **Done, tested**: P-256 root CA (Keychain-persisted, in-memory store for tests); per-host leaf certificates signed on demand and cached as TLS server contexts. CONNECT is MITM-decrypted — TLS terminated with the minted leaf, plaintext captured, re-forwarded upstream. SSL-proxying scope list (wildcard include/exclude; `exclude` = pinned/pass-through). MCP gains `get_certificate_status`, `get_ssl_scope`, `set_ssl_scope`, `export_ca_certificate`. Proven end-to-end by a NIO-client-through-proxy integration test (`Engine/ProxyCore/Tests`).
- **Half of the old "ruled out" was wrong, and 0.0.17 acts on the difference.** This entry used to say the XPC helper *cannot be enabled at all* on an ad-hoc build, resting on two refusals: `SMAppService.register()` declining a root daemon with no trust anchor, and the helper's caller requirement declining an ad-hoc app. The first is **measured false** — a throwaway probe (one bundle ad-hoc, one signed with a free-account Apple Development identity) registered, reached `requiresApproval`, was approved once in Login Items, and ran as uid 0 in both cases. The second was real but was **our own string**: `anchor apple generic` is unsatisfiable for an ad-hoc caller, and nothing forced us to write it.

  So a root helper ships in 0.0.17 (`loom-helper`), and it is scoped to the **system proxy + pf QUIC block** — the thing that made every enable cost an admin password, since `/dev/pf` is root-only even for admins. `HelperRequirement` derives the strongest caller check the build's signature supports: identifier + team OU with a real identity, identifier alone when ad-hoc.

  **What stays ruled out is system-domain CA trust, and now for a stated reason rather than an assumed one.** An `identifier`-only check is forgeable by any local process, so the helper's surface is confined to operations an admin account can already perform silently or whose worst case is a reversible local denial of service. Installing a machine-trusted root CA is neither: forgeable caller + root CA is machine-wide MITM. That needs a non-forgeable signature, i.e. a Developer ID certificate, which remains a standing decision not to buy.

  What ships for CA trust, and is sufficient: **user-domain** trust (the console's "Install & Trust" → `CertificateTrust.installUserTrust`, one login-password prompt). The system-proxy half no longer gives up the prompt — that is what the helper bought — but the un-escalated `networksetup` + one-osascript path remains the fallback whenever the helper is absent, unapproved or silent. What is still consciously given up: non-admin users, and the helper's crash watchdog (a crashed Loom's leftover proxy/QUIC override is instead surfaced and cleared by the next launch's boot sync). The manual system-domain route stays documented for anyone who wants it: `export_ca_certificate` → `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain <path>`.

  **The code was deleted in 0.0.16** (`Engine/PrivilegedHelper`, the `HelperProtocol` module, the XPC half of `Clients/PrivilegedHelperClient` — ~1000 lines, two Tuist targets). It had been kept "as a design record" on the argument that deleting it means rewriting it if the decision reverses. That argument lost: the decision is not reversing without a Developer ID certificate nobody is buying, and in the meantime a thousand lines that never load, never run and are never exercised by CI cost every reader the work of establishing they are dead before trusting anything nearby. What genuinely needed keeping is the *reasoning* — why `SMAppService` and the caller requirement both refuse an ad-hoc binary, and why both refusals are correct — and that is above, in this entry, where someone proposing the idea again will actually read it. The implementation is in `git log`.

### M3 — Write actions, closed loop

- `set_rule` (map local / map remote / block / rewrite header / throttle) — done. `diff_flows` — **done**: structured request/response diff (method/url, header add/remove/change, status, line-level body diff for text); `base` alone diffs a replay against its `replayedFrom` original, closing the capture → modify → replay → diff loop over MCP.
- Breakpoints — **done**: `arm_breakpoint` (match reuses `RuleMatch`; pause request and/or response) → held exchange surfaces in `list_pending` → `resume` with edits (method/url/status/headers/body) or `abort`. MCP has no server push, so the *transport* is still request/response — but an agent doesn't poll: `wait_for_pending` blocks until a hold lands (`BreakpointStore.pendingStream()`). Implemented as `BreakpointForwarder`, the outermost `UpstreamForwarding` decorator, backed by a lock-based `BreakpointStore` that parks the exchange on a continuation; non-matching traffic (incl. streaming) is delegated untouched, and an unattended hold auto-proceeds after a timeout so a client can't hang forever. Not persisted (a held exchange holds a live connection open).
- **Write-action safety**: the MCP control plane binds loopback-only (not the LAN-exposed proxy port) and every write is recorded in a durable audit trail; write tools act directly, with no approval gate (owner decision — see [`INTERACTION.md`](INTERACTION.md)).
- **Rule-model authoring surfaces — done.** The model has exact-match, host/query predicates, and base64 (binary) mock bodies. The `set_rule` MCP schema exposes `is_exact`/`host_pattern`/`query`/`body_base64`, so agents can author them (round-tripped in `list_rules`). The SwiftUI Rule editor now surfaces the same set: an exact-match (`=`) toggle beside the regex toggle (mutually exclusive), a collapsible **Match conditions** group (host glob + query key/value predicates), and a **Binary (base64)** mock-body mode — all round-tripped through `RuleDraft` so editing an agent-authored rule no longer silently drops them.

### M4 — Protocol breadth

- HTTP/2 (`swift-nio-http2`), WebSocket frame capture, GraphQL-aware inspector — **done**.
- Persistent store — **done** (SQLite, not GRDB): completed flows persist to `~/Library/Application Support/com.loom/flows.sqlite` and reload on launch; HAR **export** ships (`export_har`), and — M6 — HAR **import** (`import_har`, flows labelled `importedFrom`, unusable entries counted) plus **redacted evidence bundles** (`export_har(redact:)`: credential headers and token query params replaced, never deleted; optional body drop keeping sizes).
- Stream request bodies — **done**: uploads no longer buffer whole in memory. The request handlers bridge inbound body chunks into a back-pressured async stream (`RequestBodyBridge`, built on `NIOThrowingAsyncSequenceProducer` + a high/low-watermark strategy driving `channel.read()` with `autoRead` paused), and `NIOStreamingForwarder` relays chunks awaiting each flush so a slow upstream back-pressures the client — in-flight bytes stay bounded to the watermark, not the body size. Forwarding starts on the request head (lower latency) instead of after the last byte. A capped `RequestBodyCapture` tees the body for the inspector. Pure passthrough streams; a request-body-mutating rule / short-circuit / matching breakpoint buffers (`RequestBody.collect()`). Applies to **both HTTP/1.1 and HTTP/2** — the stream starts lazily on the first body chunk, so an h2 DATA body with no Content-Length streams too, and the bridge's `read()` replenishes the h2 flow-control window. WebSocket was already streamed (a separate byte-transparent frame splice, never buffered). (There was never a real 413 cap — this replaces unbounded buffering with bounded streaming.)

### M5 — Operability, quality & correctness (done)

Hardening the AI-operated loop for sustained real use. The operator is an agent with no human watching each step, so failures must be **bounded** and **observable**.

- **Flow-store durability & bounds — done.** Completed flows flush on quit; in-flight flows are finalized as `interrupted` rather than silently lost. The in-memory ring and the UI flow list are count-bounded, and the list surfaces when it has dropped older flows (no silent truncation). Bodies live **out-of-line**: SQLite stores them in dedicated BLOB columns (list/boot reads stay body-free), the engine ring drops the oldest *persisted* flows' bodies once over a 64 MB budget and re-hydrates on demand, and the UI holds metadata only — fetching a body when a flow is opened. Bounds the three RAM/disk sinks a big or large-body capture would otherwise blow up.
- **Dev infra — done.** The whole test suite runs on **Swift Testing** (XCTest retired); `tuist install` uses the **SwifterPM** resolver (content-addressable, sub-second warm resolves, worktree-friendly); the SPM C-shim targets are static frameworks so clean/`tuist run` builds don't hit the CNIODarwin "Copy Module Map" cycle.
- **Logging & audit trail — done.** The MCP write surface (replay / rules / breakpoints / ssl-scope / har) now records a durable **audit log of write actions** — the choke point is `MCPToolExecutor.call`, entries persist to `audit.sqlite` (row-capped, survives relaunch), and the trail is surfaced to the supervising human in the main-window **sidebar → Audit** panel and to an agent via the `get_audit_log` MCP read tool. Reads are never logged; a test pins the audited set to the "write action"-marked definitions so a write can't slip past. The **fail-open paths now log at error level** (`Log.audit`/`Log.rules` join `proxy`/`tls`/`forward`/`store`/`websocket`): a corrupt or unreadable CA store — which silently regenerates a root CA and invalidates the trusted one — an unopenable flow/audit database, a dropped persistence write or undecodable row, an unreadable rules file (every rule vanishing, so "mocked" traffic quietly hits the real upstream), an undecodable SSL scope (interception silently off), a `mapRemote` whose destination doesn't parse (reported as applied while the request went to the original origin), and an unreadable `mapLocal` file. `os.Logger` stays; a pluggable backend waits until a non-Apple embedder needs it.
- **CI gate — done.** Until now the only workflow was tag-driven `Release`, which archives and never tests: ~425 tests ran on developer machines and nowhere else. `.github/workflows/ci.yml` now runs on every PR and push to main — the full Tuist graph + all five test bundles, plus `swift build`/`swift test` on the root `Package.swift` so the embeddable-library graph can't rot unnoticed. The gate is **not** xcodebuild's exit code: `scripts/assert-tests-ran.sh` reads the result bundle and fails unless every expected bundle actually executed, because a stale project makes xcodebuild print `** TEST SUCCEEDED **` after running zero tests. **Thread Sanitizer** on `ProxyCoreTests` is blocking and its baseline is clean — 229 instrumented tests, zero races, the first real check on the Swift-5 `@unchecked Sendable` channel handlers. It only runs in CI: TSan's runtime segfaults during its own init on macOS 26, so an incomplete run is reported inconclusive rather than clean.
- **Correctness guarantees — done.** The five invariants that, if violated, corrupt what the agent believes are now named and pinned in `EngineInvariantTests.swift`, one suite each: **one write path** (a replay obeys the rules and breakpoints armed for live traffic, and stays visible/resumable while held), **body hydration** (the same bytes come back whether a body is live in the ring, slimmed by the byte budget, or evicted to SQLite — and the list read never hydrates while detail/export do), **one rule choke point** (buffered and streaming forwarding reach identical verdicts, including short-circuits), **breakpoints always release** (every exit — resume, abort, disarm, timeout, client hang-up — frees the exchange, and racing resolvers claim it at most once), **replay links its flow** (succeeded, rule-answered or failed, each records exactly one flow pointing back at its source, even while capture is paused). Each was mutation-checked: breaking the invariant in the source makes exactly its test fail, so none of them pass vacuously. Fault injection now also covers the durable stores — an unopenable database, a file SQLite opens but can't use (writes silently dropped), an undecodable row, and the same on the audit trail — alongside the CA / rules / SSL-scope faults already there.

### M6 — Cheaper agent loops (done)

M1–M5 made the loop *possible*; this round made it cheap. The operator is an agent
paying for every round trip in tokens and latency, so each item here removes a poll
loop, a guess, or an arithmetic detour:

- **Content search** — `get_recent_flows` gains `header_contains` / `body_contains`
  (ASCII-folded byte scan, no allocation per flow; a body predicate hydrates only
  candidates that already passed the cheap predicates, and results stay body-free).
  "Which request carried this order id" no longer means paging `get_flow_detail`.
- **Blocking waits** — `wait_for_flow` / `wait_for_pending`: query the retained
  capture first, subscribe *before* checking so nothing falls in the gap, and treat a
  timeout as a normal result whose `windowFrom` cursor makes a retry gapless. The
  default window looks 10 s back, because the natural order is trigger-then-call.
  Transport-side: dispatch is off the event loop (a held request can't block other
  calls) and a client disconnect cancels the waiter — which required dropping NIO's
  pipelining assistance, since it holds back reads and hid the peer's EOF.
- **Aggregation** — `get_stats` (host / endpoint / status / app / device buckets:
  counts, error rates, exact TTFB+duration percentiles, slowest exchanges with ids).
  A percentile over one page of summaries isn't a percentile.
- **Batch replay** — `replay_flow(count:concurrency:)` for "is it intermittent / does
  it survive parallel load", with failures reported rather than thrown.
- **Origin-scoped rules** — `RuleMatch` gains `sourceApp` / `deviceIP`, threaded to
  the matcher through `forwardStream(…, origin:)`; fail-closed on unattributed
  traffic, inherited by replays, surfaced in the rule editor so a human's Save can't
  silently widen an agent's scope.
- **Routing visibility** — `get_proxy_status` reports `listenHost` / `lanReachable`
  and a three-valued `systemProxy` (`on`/`off`/`unavailable`), and
  `set_system_proxy` can fix it, confirmed by reading the state back.
  `SystemRoutingControlling` is injected by the app, keeping the layering one-way.
- **HAR both ways** — import (above) and redacted export, so a capture can arrive
  from a colleague and leave for a ticket.

### M7 — Cross-surface parity (done)

M1–M6 grew the agent's surface. This round audited the architecture behind both
surfaces and fixed what had rotted; what it *found* is the phase.

Closed with one capability built (breakpoint supervision — the only item that was
a real supervision gap) and three items **decided rather than built**. That ratio
is the phase's actual lesson: an audit produces a list, and a list read as a
checklist quietly promotes "not done" into "to do". Each of the three was measured
against the value hierarchy instead — does the human lose control of risk without
it? does it cost more than it removes? — and each came back no. Written-down
decisions with reopen conditions, so the next pass doesn't rediscover them as work.

**Done — the drift is now caught by the compiler or by a test** (PRs #103–#110):

- **`ProxyCapability` + `ProxyClientParityTests`** — every `ProxyControlling`
  requirement must be reachable from the human's `ProxyClient` or recorded as a
  deliberate omission with a reason. It found the real one: every breakpoint
  capability was reachable over MCP and absent from the client, so an agent could
  park a live client connection with nothing in the human's surface able to see
  it or let it go. Plumbing closed, and the panel now exists too (see below).
- **`RuleCodecParityTests`** — a rule exists four times (model, `set_rule` schema,
  `list_rules` render, the editor's `RuleDraft`) and only the model is
  compiler-checked. A reflection census now fails when a field stops being
  settable or readable on any of the other three.
- **`FlowComparison`** — `diff_flows` and the Inspector's diff pane computed
  *different diffs*: the tool reported response headers and a line-level body
  diff, the pane reported `body: changed` and no response headers. One semantics
  now, rendered two ways. A human comparing notes with an agent was previously
  comparing two different answers.
- **Structure**: one designated `ProxyEngine` initializer behind
  `EngineConfiguration` (three hand-mirrored wirings, held together by a comment);
  the 730-line engine façade and the 2256-line MCP tool registry split by
  protocol/concern; the privileged-helper XPC contract moved out of the published
  `LoomSharedModels` product into `LoomHelperProtocol`; `SetupFeature`'s view of
  the proxy projected from `status` instead of copied into it at three call sites.

**The phase itself.** Adding a capability the *engine* needs is cheap: the
decorator chain and the single choke point absorb it. Adding one that **both the
agent and the human** need is more expensive, and that asymmetry is what M7 was
about. All four items are now settled:

1. ~~**Breakpoint supervision has no UI.**~~ **Done.** `BreakpointsFeature` mirrors
   armed + held state from the engine (boot seed → `pendingBreakpointStream` →
   re-sync after every write, plus a 2 s poll that runs *only* while something is
   held, because a hold can resolve with no decision from us — client hangup, or the
   engine's watchdog). Two surfaces consume it: the main window's **sidebar →
   Breakpoints** panel (held exchanges lead, each with resume/abort inline; armed
   breakpoints below with disarm), and an orange **Breakpoints** row in the
   status-bar console that appears only when something is armed or held, names the
   held requests, and jumps straight to the release surface. Editing a held exchange
   stays with the agent (`resume` + `BreakpointEdit` over MCP); the human gets
   proceed-unmodified and abort. Value #2 is no longer violated by the one write
   action that parks a live connection.
2. ~~**The parity guard records omissions that are really UI gaps.**~~ **Closed —
   they stay agent-only, by decision.** HAR import/export read as unfinished work
   ("wire this the moment the window grows a drop target"), so this item existed to
   finish them. Judged against the value hierarchy rather than the checklist, they
   don't survive: an import or an export **touches no live traffic**, so unlike
   a breakpoint — which parks a real client connection and was the genuine
   supervision gap item 1 closed — their absence costs the human no control over
   risk. The agent's `import_har` / `export_har(redact:)` are complete, redaction
   included, and imported flows land in the shared store where both surfaces see
   them. Building the human half means a save panel over a body-hydrating read
   (`recentFlowsForExport` pulls every blob — see 0.0.12's #171) for a low-frequency
   action, which is precisely the "chrome the AI never sees" the positioning
   section rules out. The two omissions are now recorded as decisions with that
   reasoning and a reopen condition: a routine hand-off performed with no agent at
   hand. `setRules` and `replayFlow` were already deliberate; `recordAudit` must
   stay single-writer or a UI action could forge an audit entry.
3. ~~**A cross-surface capability still costs ~5 edits.**~~ **Decided: keep the
   struct of closures.** The count was also understated — a full cross-surface
   capability is ~9 edits (protocol, `ProxyCapability` case, engine, MCP schema
   entry, MCP handler, `ProxyClient` field, `liveValue` line, feature, view) — but
   wrapping `any ProxyControlling` removes exactly **two** of them, the field and
   the `liveValue` line, and those two are the ones doing work:

   - **`liveValue` completeness is compiler-enforced today.** `@DependencyClient`
     strips an endpoint's default off the generated initializer, so all 40 fields
     must be assigned; forgetting one doesn't compile. A protocol reference trades
     that for "the engine implements it, the UI never calls it" — silent, and
     precisely the drift `ProxyCapability` exists to catch.
   - **54 test sites stub one endpoint at a time** (`$0.proxyClient.flow = { … }`),
     and an *un*stubbed endpoint reports an unimplemented failure. Replacing this
     with a mock conformance means hand-writing ~36 traps to keep that property.
   - `ProxyClient` is also not the pure mirror the item assumed: 9 of its 40 fields
     (engine start/stop, user-domain CA trust, phone onboarding, the connected-device
     count) have no `ProxyControlling` requirement at all, so the struct survives the
     refactor regardless — it just stops being readable as "what the human can do".

   Reopen if the surface roughly doubles, or if a second feature-layer client
   appears — two hand-written mirrors is a different problem from one.
4. ~~**Rule authoring still has four representations.**~~ **Closed — one real
   duplicate removed, the rest don't collapse.** Read closely, the four are not four
   copies of one thing. `RuleMatch` was genuinely rendered **twice** (identical code
   inline in `list_rules` and in `matchDict`, the breakpoint tools' renderer), so a
   predicate added to one copy would have made the same scoping read back
   differently depending on which tool an agent asked — that one is now shared, and
   pinned by a test that renders one match through both surfaces. Its other two
   sides were already single: one parser (`ruleMatch(from:)`, used by rules *and*
   breakpoints) and one advertised schema (`matchSchema`).

   What remains is not duplication. The input schema (snake_case, flattened route,
   create-vs-update semantics) and the `list_rules` render (camelCase,
   omit-when-default, truncated bodies) are deliberately *different shapes* for
   different readers — merging them would mean inventing a third shape neither
   wants. And `RuleDraft` is not a serialization at all: it is a form model, with
   `String`-typed number fields, headers as a text blob, and five `carried*` fields
   whose entire job is to preserve what the editor deliberately doesn't show.
   Folding it into a codec means rewriting the editor to be generated, which costs
   far more than the census it would replace. So the census stays as the guard; if a
   *fifth* surface appears (a rule-import format, a config file), collapse before
   adding it.

### M8 — Capture reach (done, 0.0.10)

M1–M7 assumed the traffic arrives. This round is about the traffic that never
does. Measured against Charles / whistle / mitmproxy, Loom's capture breadth had
three real gaps — not protocol-parsing gaps, *arrival* gaps:

1. **Clients that don't speak HTTP proxying — done (SOCKS5 listener).** The HTTP
   proxy port only sees a client that sends an absolute request URI or a `CONNECT`.
   A Go/Rust/Node CLI honouring only `ALL_PROXY`, a tool whose sole proxy field is
   a SOCKS one, and anything that isn't HTTP at all were invisible — which reads
   as "nothing happened", the exact ambiguity M6 spent a phase removing elsewhere.
   A second listener (`port + 1`, reported as `get_proxy_status.socksPort`) now
   terminates SOCKS5 and hands the connection to the *same* capture stack.

   The interesting constraint is ordering: a SOCKS client sends nothing until it
   gets a success reply, so Loom must accept the connection before it can look at
   one application byte. Deciding capture strategy from the port number would
   therefore capture nothing on the non-standard ports that are half the reason to
   add this. So the reply goes out first and the first bytes are sniffed
   (`ProtocolSniff`): a TLS record MITMs if the host is in SSL scope, an HTTP
   request line is captured in cleartext, everything else — h2c prior knowledge
   included — is relayed byte-transparently and recorded as a tunnel flow when the
   embedder asked to observe tunnels. The cost of replying first is that an
   unreachable upstream is discovered after having already said "succeeded", so the
   client sees a closed connection instead of a SOCKS error; mitmproxy's SOCKS mode
   makes the same trade, and it is strictly better than declining to capture.

   Sniffing needed a deadline, and finding out why is the lesson of this phase.
   Classifying on the client's first bytes assumes the client speaks first; SSH,
   SMTP, IMAP, MySQL and PostgreSQL are *server-first*, so they deadlocked outright —
   the client waited for a banner Loom had not opened an upstream connection to
   fetch. Every test passed, because the opaque-relay test's payload happened to be
   client-first. It surfaced the moment a real `nc -X 5` was pointed at a real SSH
   server, which is why "verified" now means through the running app and not through
   a green suite. Sniffing carries a 150 ms deadline; only server-first connections
   ever pay it, and each pays it once.

2. **mTLS (client certificates) — done.** A target that requires a client
   certificate made Loom's upstream handshake fail outright, so those APIs could not
   be captured at all — a narrow feature with a hard failure mode, which is why it
   ranked above the wider one below. `ClientCertificate` (PKCS#12 + passphrase,
   scoped by host glob) is stored in `client-certificates.json` (0600) and consulted
   per upstream host by `NIOStreamingForwarder`; three MCP tools plus `ProxyClient`
   endpoints expose it, and the status-bar console carries a collapsed **Client
   Certificates** row under HTTPS (list, add via file picker, confirmed delete).
   Deliberately a row and not a sidebar panel — the existing panels are for activity
   that needs supervising while it happens, and this is the lowest-frequency
   configuration in the app.

   **Per-flow attribution is deferred, deliberately.** Recording *which* identity a
   flow presented, as a `Flow` field, was the obvious next step and is the wrong one
   for now: it answers "which one", while the actual pain is "why did this fail" — and
   the failure usually happens when there is no identity to attribute. It would also
   touch a public model and everything downstream of it (HAR, `get_flow_detail`,
   `FlowComparison`, the Inspector, redaction) for value that only appears once
   several overlapping host patterns exist. What shipped instead is `UpstreamTLSError`:
   a refused handshake names the host and which identity was presented (or that none
   was), in `Flow.error` — one file, every surface, no model change. Revisit the field
   when there are enough identities that "which one matched" is a real question.

   Three decisions worth keeping: the bundle is **validated when it is set**, so a
   wrong passphrase lands on the operator who typed it instead of on a request hours
   later attributed to the origin; a configured-but-unloadable identity **throws**
   instead of quietly connecting without it, for the same reason; and the audit trail
   **redacts** the bundle and passphrase, because a durable on-disk record of what an
   agent did must not double as a copy of the operator's key material. Host scoping
   is not cosmetic either — presenting a certificate identifies its holder to whoever
   asked, so an identity meant for one internal API must not be offered to every host
   that requests one.

3. **Failures say which identity was presented** (`UpstreamTLSError`) — an mTLS
   refusal used to read as a localized `NIOSSLError error 0` with no host and no
   hint. The wrap has to sit in the response handler, not around `connect()`: TCP
   succeeds and the handshake fails afterwards inside the pipeline. And it reports
   what Loom *did*, never what the server *wanted* — a client-certificate
   requirement arrives as a TLS alert, and under TLS 1.3 a rejection can surface
   after the handshake looks complete, indistinguishable from an ordinary reset.

4. **Processes that ignore every proxy setting — deliberately not planned.** Only
   transparent interception (pf `rdr` plus recovering the original destination
   through `/dev/pf`'s `DIOCNATLOOK`) reaches those, and it is the most expensive
   item on this list by a wide margin: root, a hand-rolled ioctl struct, and
   destination inference when there is no SNI. It is also the item an *agent* can
   never perceive — Loom's value hierarchy puts "the agent can finish the job"
   above protocol breadth, and mitmproxy already exists for the transparent case.
   Revisit only if empty captures on this Mac turn out to be dominated by
   proxy-ignoring processes rather than by routing that was never turned on.

### Known-Issues audit (done, 0.0.11)

No new capability — a pass over every entry in AGENTS.md § Known Issues, checking
each claim against the code rather than trusting it. All 16 entries were real and
broadly accurate, which was the reassuring half. The other half: **four of the
described fixes didn't work, and three entries described code that doesn't exist.**

The lesson is narrow and worth keeping: *a documented claim with no gate behind it
decays, and the doc goes on asserting it.* Every defect this round found sat behind
a sentence that read as settled.

1. **The worst one was invisible by construction.** "Enabling the system proxy also
   blocks QUIC" was false for admin users — the most common setup, and the one the
   entry itself called out as silent. `networksetup` needs no auth for an admin, so
   the un-escalated run "succeeded"; every `pfctl` in it needed root and failed with
   stderr swallowed by design. The proxy check passed, so nothing escalated, nothing
   logged, and the panel said "QUIC blocked" while browser HTTP/3 bypassed Loom
   entirely. A capability can be fully implemented, fully documented, and never once
   execute. The fix makes the script's **exit status** the contract, which costs
   admin users one auth prompt — the honest price of the feature working at all.
2. **Two fixes were fail-*open* where they claimed to be safe.** The QUIC blocker
   synthesized an empty `pf.conf` when it couldn't read the baseline and loaded it —
   `pfctl -f` replaces the whole ruleset, so a merely-unreadable `/etc/pf.conf`
   meant Loom silently replaced the user's firewall with one rule. The CA migration
   swallowed its write failure with `try?`, so a failed migration was
   indistinguishable from a fresh install and quietly invalidated an already-trusted
   CA. Both now fail closed, and the second is testable at all for the first time.
3. **An unconditional fix broke the case it didn't consider.** The forwarder strips
   `Content-Encoding` because it decompresses — but it only inflates gzip/deflate,
   while forwarding the client's `Accept-Encoding` verbatim, and every browser
   advertises `br`. So a `br` response reached the client still compressed with the
   header it needed to decode it removed. The regression test used `br` as its
   example, codifying the bug as the spec.
4. **Three entries described code that isn't there** — a module name that never
   existed, a `pfctl -nf` validation nothing ran, and a `set_system_proxy` reply
   claiming it restored the previous proxy owner, which is the exact opposite of a
   written owner decision. That last one is the dangerous shape: the doc is right and
   the *code* lies, to an agent, in a sentence it will relay.

What the round changed structurally: two claims that were prose became gates
(`check.py`'s symbol-resolution check and the pf ruleset's syntax validation now run
in CI), and the h2-stall instrumentation learned to say *whose* bug it is — bytes
alone can't separate upstream's missing `WINDOW_UPDATE` from a Loom read-pump
regression, since both park at exactly one flow-control window.

### Cost under live traffic (done, 0.0.12)

Again no new capability. AGENTS.md has called performance "a hard requirement, not
a nice-to-have" since M5, and the rules it lists (lazy containers, O(1) upsert,
bounded collections, bodies out-of-line, cheap row bodies) were all being followed.
The round measured the app *while traffic was arriving* anyway, and every defect it
found lived in the gap between "this collection is bounded" and "this work is
bounded" — a capped structure re-walked, re-parsed or re-materialized per render or
per upsert, indefinitely.

- **The container itself was the worst offender.** A sidebar category switch inside
  `NavigationSplitView` cost **8.7 s of main thread** after 600 flows had arrived
  live; `HSplitView`, same view, same procedure: **143 ms**. The quadratic is AppKit
  KVO teardown across accumulated row *hosting views* — so its N is what tail-follow
  scrolling accumulated, not the row count, which is why a static rig never
  reproduced it. Full record in [`docs/performance/navigation-split-view-kvo.md`](docs/performance/navigation-split-view-kvo.md).
- **Render-time recomputation** — the inspector re-ran a recursive-descent JSON parse
  over up to 200 KB on every re-render (~10/s under live traffic, and it retried a
  parse that had already failed), rebuilt raw request/response strings from
  multi-MB bodies, and materialized the filtered flow array a second time just to
  test emptiness. Parses and joins now run once, off the main actor, keyed on the
  bytes rather than the pane — identity is deliberately stable across hydration.
- **Per-item work where per-batch was intended** — the display cap was enforced once
  per flow inside a batch, and `IdentifiedArray.removeFirst` is O(count), so a list
  pinned at its 2000 cap paid O(n·m) per 100 ms window forever. That is precisely
  the shape the stream batching exists to prevent.
- **Scans that restarted from zero** — `enforceBodyBudget` re-walked the ring from
  index 0 on every over-budget upsert, and over-budget *is* the steady state of a
  long capture. A slim cursor now marks the leading body-free run, and pulls back
  when a late WebSocket frame re-attaches a body behind it.
- **Synchronous disk on the actor** — `flow(id:)` / `recentHydrated` / the
  `body_contains` path called persistence (`queue.sync`) from inside `FlowStore`, so
  one HAR export or one unnarrowed body search parked the actor and queued *every*
  in-flight capture upsert behind it. Hydration now runs on detached tasks off a
  ring snapshot.
- **A resolver wait nobody needed** — every forwarded request awaited
  `ProcessResolver` (worst case a full libproc sweep, tens to hundreds of ms) so
  that app-scoped rules could match. `UpstreamForwarding.requiresSourceAppResolution`
  now asks the chain whether anything actually matches on the source app; when
  nothing does, TTFB stops paying for it.
- **Bounds an agent could blow past** — the console's rules row rendered one line per
  enabled rule (200 rules → a 200-row popover), and the audit detail sheet handed a
  write tool's full arguments to a single `Text`, which lays out synchronously and a
  mock body is hundreds of KB. Both capped, with an honest "showing first N of M";
  the durable row keeps the full value.

The other half of the round was documentation: the specs had accumulated a dead
approval-card design and "v2" vocabulary for a UI generation that no longer exists,
AGENTS.md was mirroring ROADMAP narrative instead of pointing at it, and a skill
claimed `set_system_proxy` restores the previous proxy owner — the opposite of the
written decision. Same failure mode as the 0.0.11 audit, one layer up. CI now skips
the build jobs on docs-only changes, and **ad-hoc signing is recorded as a decision**
rather than a gap, which parks *system-domain CA trust* for good (§ M2 — the system-proxy helper is a different question, and shipped in 0.0.17).

### What the agent can see (done, 0.0.13)

The first round measured by **driving the MCP surface** instead of reading the
code: eight scenarios a real operator hits — an empty capture, "which request
carried this id", "why is this slow", a pinned/expired HTTPS host, replay-and-diff,
mock a failure, scope a rule to one app, edit a request in flight. Three passed
outright (`get_stats` answered "server or transport" in one call; capture → replay
→ `diff_flows` in three; breakpoints held, edited and released). The other five
produced eight defects, and half of them were the same defect wearing different
clothes.

**The pattern, and the rule that comes out of it.** In four cases Loom *knew* the
thing that decided whether the agent's next action was correct, and had no way to
say it:

| Loom knew | The agent got |
|---|---|
| `CERTIFICATE_VERIFY_FAILED` — we refused the server's certificate | "Loom presented no client certificate … install one with `set_client_certificate`" |
| the rules master switch is off | a clean `set_rule` echo, `"enabled": true` |
| the first byte was `'G'`, not a SOCKS5 greeting | nothing at all |
| the port table predates this connection | `null`, and an app-scoped rule failing closed |

M5 established "the engine fails open by design — but never silently", and
discharged it with `os_log`. That is one output, aimed at a human with Console
open. **Loom's primary operator is an agent, and it cannot read `os_log`.** So the
rule this round adds: *a fact the engine holds that determines whether an
operator's action was correct must be reachable from a tool, not only from a log
line.* Concretely — a refused connection is counted and described in
`get_proxy_status`; a rule write reports `effective` and why not; a TLS failure
that is provably ours to explain says which side rejected whom.

Two of the eight were not silence but plain breakage, and both were invisible
without running the thing: an app-scoped rule matched **1 of 12** identical
requests (a freshness test asking "how old is the table" rather than "could the
table have contained this connection"), and the wrong half of a TLS diagnosis
pointed the agent at a write action needing the operator's private key. Two more
were the tool answering a near-miss question — content search that could not say
*which side* of the exchange to look at, and a latency aggregate missing the very
number that separates a slow server from a big payload.

Two methodology notes worth keeping, because both changed a conclusion:

- **Measure before designing around a cost.** The resolver's 0.25 s rescan window
  existed because a comment estimated a `libproc` sweep at "tens to hundreds of
  ms". Measured: **~3 ms**. The guard the estimate justified was the bug.
- **A green suite is not the experiment.** The mutual-TLS test had been passing
  for the wrong reason (its no-identity path never trusted the test CA, so it died
  at server-certificate verification rather than the refusal it claimed to prove),
  and the burst failure only appeared through the running app. "Verified" keeps
  meaning what M8 said it means: through the app, not through the suite.

### Reverse-proxy endpoints (done, 0.0.15)

A local port that stands in for one upstream origin: Loom accepts plain HTTP on it,
captures, and forwards to the configured upstream. Charles has had this for years
("useful if you have a client application that doesn't support the use of an HTTP
proxy, or you want to avoid configuring it to use a proxy"), and its absence here
was the one real capability gap behind a complaint that Loom "can't see a dev
server's forwarded requests".

**The premise was half wrong, which is why this got measured before it got built.**
Same Node process, same `HTTP_PROXY`, same target, only the HTTP library changed:
axios captured, global `fetch` (undici) not. Node's built-in client ignores proxy
environment variables entirely (`NODE_USE_ENV_PROXY` is 24+; this machine is on
v20), so "Charles caught it" nearly always means that hop used a library that reads
the environment — not that Charles reaches further into the process. What Loom was
actually missing was the escape hatch for the *other* half.

Why this shape rather than the alternatives:

1. **Not transparent interception.** M8 § 4 still stands — pf `rdr` plus
   `DIOCNATLOOK` is the most expensive item on the list and the one an agent can
   never perceive. A reverse endpoint reaches the same clients for a fraction of the
   cost, and an agent can create one itself.
2. **Inbound is plain HTTP even when the upstream is `https://`.** This is the
   ergonomic win, not an omission: the client needs **no CA trust** — no
   `NODE_EXTRA_CA_CERTS`, no keychain step — because Loom terminates nothing and
   does the upstream TLS itself. An HTTPS *inbound* endpoint (which Charles offers)
   would hand that step straight back, so it is deliberately absent.
3. **The flow records the upstream URL**, never `127.0.0.1:port`. The local port is
   transport, not identity; if it leaked into the URL, every rule and breakpoint
   written against the real host would silently stop matching traffic that arrived
   this way — a failure that looks like the rule engine broke.
4. **A mode on `ProxyHandler`, not a second handler.** Everything after "which URL
   is this going to" — body streaming and its back-pressure, capture, rules,
   breakpoints, the WebSocket splice — must be identical on both entry points, and
   the way that stops being true is by having two copies (the lesson `MITMPipeline`
   already records for the HTTP and SOCKS entry points).
5. **Create binds before it persists; boot fails open per endpoint.** A create has a
   caller waiting for an answer, so it throws rather than register an endpoint whose
   port refuses every connection. A relaunch has no such caller, so one taken port
   must not stop the others — the reason lands in `ReverseProxyStatus.error` and in
   `get_proxy_status.reverseProxies`, because "configured but not listening" is
   experienced by the client as connection refused, i.e. as Loom being down.

Endpoints persist (`reverse-proxies.json`), because their port is written into a dev
server's config file that Loom restarting does not edit — an endpoint that evaporated
on quit would break the developer's setup every morning, silently.

Shipped alongside it, from the same investigation: the forward-proxy port's `400` for
an origin-form request line now records a **refusal** (`RefusalLog`, so
`get_proxy_status.recentRefusals`) with advice specific to that mistake. Pointing a
dev server's proxy target at Loom's proxy port is exactly the right instinct and
exactly the wrong port, and the old bare `400` left the agent looking at an empty
capture and a status reporting no problem.

### The TSan hunt (0.0.15) — three real bugs, and the one that wasn't ours

The reverse-proxy round turned the `Thread Sanitizer (ProxyCore)` job intermittently
red. Chasing it took four wrong turns worth writing down, because each one was wrong in
a way that looked convincing:

1. **"It's the stale `defer`."** The first crash was attributed to a `defer` in a test
   that had already finished — real, fixed, not the cause.
2. **"It's `stopAll` iterating what it mutates."** Also real (undefined behaviour on
   every engine stop), also fixed, also not the cause.
3. **"25 clean iterations prove it."** They did not: the clean run tested one suite and
   the failing runs tested the whole thing. **Comparing across different selections is
   not a before/after** — the single most expensive mistake of the round, because it
   ended the investigation for a while.
4. **"It's the leaked event-loop groups."** `ProxyEngine` never shut its
   `MultiThreadedEventLoopGroup` down, so a run left hundreds of loops alive. A real
   defect for embedders, fixed — and the control still reproduced at iteration 2.

What settled it was a **control**, not another theory: run the whole suite with the
reverse-proxy tests excluded. It still reproduced. Every racing frame belongs to NIOCore
or the Swift runtime, the signature matches `swiftlang/swift#57803`, and
`Tools/tsan-continuation-repro/` shows it in ten lines with no NIO and no Loom.

Two things this round earns beyond the fixes: the dispatch-only hunt workflow (narrow by
`suite`, exclude by `skip`, repeat by `iterations` — repetition in one process is what
makes an intermittent race appear inside a single job), and the habit that produced the
answer: **when a failure is attributed to your new code, the cheapest decisive
experiment is to run everything without it.**

### The window catches up with the store (0.0.21)

The list showed 2 000 exchanges while the store retained 20 000, and everything built on
that number was wrong in the same direction: the sidebar counted the window rather than
the capture, and a *filtered* read stopped at the ring, so nine of every ten persisted
flows could not be found by any search — while `flow(id:)` resolved them perfectly well.
An agent could hold an id that worked and search for the same exchange to `[]`, which
reads exactly like "that traffic never happened".

Closing it took four steps, and each one was gated on a measurement rather than a
preference:

1. **`FlowPage`** — keyset paging over ring + history. Not an offset: an offset is a
   position in a list the capture keeps prepending to, so by page 3 the rows have moved.
   The `(startedAt, id)` tiebreak is not decoration either — timestamps collide by the
   dozen inside one page load.
2. **The counters moved to the engine**, over everything retained. Three rules hold them
   exact and each is a place the obvious version drifts: leaving the ring is not leaving
   the capture, an upsert re-counts, and the pruner deletes rows nobody upserted.
3. **The table became an `NSTableView` this app owns.** SwiftUI's `Table` evaluates only
   visible row bodies — 32 of them whether the data is 2 000 rows or 100 000 — but walks
   its whole collection about five times per data change (100 006 subscripts for 20 001
   rows, 70–120 ms). At a capture batch every 100 ms that is the main thread, and it
   makes a paged source impossible by construction.
4. **The cap went to 20 000**, seeded from the durable store after launch rather than in
   the ring — restoring 20 000 rows into the ring costs 416 ms of decode on the path
   that binds the listener, for 13 MB.

What the work found on the way is worth more than the feature:

- **The ring's body budget was a no-op without a store.** `enforceBodyBudget` opened
  with `guard persistence != nil`, so an embedder had no bound at all: 625 MB of live
  bodies against 61 MB for the same traffic with a store. Unbounded memory is not the
  safe side of that trade; the loss is *recorded* (`Flow.bodiesEvicted`) instead.
- **Writing through `@ObservableState` costs work proportional to what it holds** —
  690 µs per insert at 20 000 rows against 2.6 µs into a plain container. Filling the
  window one flow at a time took 14.6 s. It was invisible at the old cap and appeared
  the moment the cap moved: the shape was always wrong and only the size showed it.
- **A footprint figure is not a memory figure.** ~400 MB of phys_footprint against a
  flat ~100 MB in use, plateauing — allocator fragmentation, not a leak
  ([`docs/decisions/write-path-memory.md`](docs/decisions/write-path-memory.md)).
- **Two bugs were only findable by looking.** The failed-row tint never drew (a
  `CALayer` inserted while `layer` was still nil), and ⌘F focused the scope picker
  instead of the field (`@FocusState` assigned before the field entered the responder
  chain). 1 112 tests were green throughout; neither is reachable from a test.

The human also got the search the agent has had since M6: `FlowQuery` had carried
`urlContains` / `headerContains` / `bodyContains` all along and `ProxyClient` was wired
to it, with no view calling it. `ProxyClientParityTests` could not catch that — it
checks a capability is *wired*, which this one was.

### The list moves instead of blinking (0.0.22)

Three PRs, all in `RequestTable`, all about the same thing: a list under live capture is
something a human *watches*, and every defect here was one where the list disagreed with
where its reader was standing.

**Tail-follow stopped being a latch.** It was a flag cleared only by a scroll
notification — and the notifications are not a complete account of how a viewport moves.
Momentum, a scroller drag, a keyboard scroll and the shift the table itself causes when
the window's head is trimmed all left it armed, so the list yanked itself back down while
the operator was reading rows further up; the same gap in the other direction stopped the
follow when a flick coasted to the bottom after the fingers lifted. There is no
bookkeeping to get wrong if nothing is booked: the update measures the viewport's own
geometry a moment before the edit lands. Two details that were each a bug first — the
measurement reads the scroll geometry rather than `rows(in:)`, which calls a row visible
when a pixel of it is; and the decision hangs off the *diff*, not a row-count change,
because at the window's cap the head is trimmed by exactly what the tail gained.

**Then the follow itself was the problem.** A batch arrived as two discontinuous events —
rows fading in at the tail, and the viewport jumping by the whole batch — ten times a
second, so the list blinked forward rather than moving, and each batch's fades overlapped
the next into a shimmer. They were two answers to one question. The insert animation is
gone and the scroll is driven frame by frame: a display link closes a fixed fraction of
the *remaining* distance per unit time, so a batch landing mid-glide moves the target and
the motion carries through it instead of restarting.

**A `ListViewKit` port was built for that and thrown away.** It gave the motion, and cost
`NSTableView`'s header, column resizing, selection and key-view loop — all hand-rolled
back, plus a `Hashable` projection of `Flow` to keep the library's diff off every captured
body. The animation turned out to be fixable in place for a fraction of that. Recorded
because the shape recurs: *a rendering defect is not automatically a rendering-stack
defect*, and the honest comparison is against fixing what you have.

Then the reverse of the first bug, from the fix to the second: drag a column wide enough
to scroll horizontally and the list **shakes**. The glide and a live scroll write the same
clip view — the gesture moves x, a batch starts the link writing y, and the two settings
of `boundsOrigin` interleave every frame. Scrolling vertically hid it, because there the
glide pushed the same axis the reader was already going. The reader owns the offset while
they are moving it, for the gesture and half a second past it (momentum outlives
`didEndLiveScroll`).

Three column jobs came with it: the list **opens at the newest row** — which is not one
call, because the first rows arrive before the view has a size, so the bottom *is* offset
0 and scrolling to it succeeds at doing nothing; **double-clicking a divider fits a column
to its content** (measured in the cell's own font, over the newest 2 000 rows, with the
header title as a floor); and **right-clicking the header chooses columns**, remembered
across launches, with hiding the last one refused on both sides — the menu that would undo
it lives on a header that by then has nothing left to draw.

## Structured Channel — decided

MCP over loopback HTTP is the transport, effective M1:

- The app hosts a JSON-RPC endpoint at `127.0.0.1:9092/mcp`; the `loom-mcp` bridge forwards stdio JSON-RPC from AI clients (Claude Desktop, Cursor) to it.
- Auth is a per-launch bearer token written to `~/Library/Application Support/com.loom/mcp-handshake.json` (mode `0600`). A loopback request may omit it (so a static `.mcp.json` can connect); a token that *is* sent must still match.
- The domain model (`Flow`, `ReplayOverrides`, rules) is transport-independent; the protocol revision moves under it without touching it.

**Two protocol revisions, one endpoint — done (0.0.9).** The server speaks **`2026-07-28`** (stateless: no `initialize` handshake, per-request `_meta` carrying version + client capabilities, those values mirrored into HTTP headers and checked against the body, `resultType` on every result, cacheable `tools/list`, `server/discover`) **and `2025-06-18`**. Dual-era is not politeness: a modern client probes and falls back, but a **legacy client cannot fall forward**, so dropping the old revision would silently disconnect every client that hasn't rolled over — Claude Code and Cursor included. The inverse mattered too: answering a modern probe with `200 OK` (which a legacy-only server does, since `tools/list`/`tools/call` share names across eras) makes a dual-era client latch "modern" and never fall back, so `UnsupportedProtocolVersionError` is what makes renegotiation possible at all.

**When `2025-06-18` may be dropped — the condition, written down now rather than argued about later.** Dual-era is a permanent tax unless it has a retirement test, and it did not have one: a compatibility layer with no stated end lives forever, and this one costs a second set of error semantics (real HTTP status codes vs `200`-for-everything), a second dispatch path, and 419 lines of `DualEraTests`. The condition is **not** "the spec moved on" — it is about the clients actually pointed at this endpoint, because the failure mode of dropping it early is that they silently disconnect. Drop the legacy era when **both** hold:

1. **Every client Loom ships a manifest for negotiates modern.** Concretely: Claude Code and Cursor send `_meta` with a protocol version on a plain request (no `initialize`), and have done so for one full release of each. That is observable without instrumentation — an `initialize` arriving on the endpoint is the era being used.
2. **A release has shipped in which no legacy *handshake* was recorded.** This is measured now rather than guessed: `MCPProtocol.decide` returns the era **and the branch that chose it**, and `MCPEraLog` counts the branches apart. Read it with `get_version.protocolTraffic` — `legacyEra` is the answer, `legacyClients` names who is still on the old revision (which is also how condition 1 is checked).

   **The answer is three-valued, and it was a `Bool` first — briefly, wrongly.** `legacyEraRetirable` read `legacyHandshakes == 0`, and `MCPEraLog` deliberately persists nothing, so the value a *cold* counter holds is the same zero a clean release would produce: a freshly launched app that had served nobody answered "retirable". Measured on 0.0.19 while writing this: `modernRequests: 0`, `legacyHandshakes: 0`, `legacyBareRequests: 3`, verdict `true` — i.e. it said the era could go at the exact moment nothing had ever negotiated the new one. So `legacyEra` is `blocked` / `unknown` / `retirable`, `unknown` being "no handshake, but no modern traffic either", and `legacyEraReason` says which and what to do next. Note this is the *same* mistake the split counters above exist to prevent, run backwards: merging the two legacy reasons would make the condition never fire, and merging "no evidence" into "retirable" made it fire immediately.

   **And the 0.0.19 reading is itself the condition-1 answer for now: Claude Code falls back.** Those 3 bare requests were Claude Code's own calls over the plugin's HTTP endpoint — it sends no `_meta`, so it never negotiates modern, and condition 1 is not close to met. The dual-era tax stays; this paragraph is the measurement, not a guess.

   **Reading this tally has one trap, and it was walked into before being written down (0.0.21).** The handshake happens **once per client connection**, and over stateless HTTP every request after it is a bare one — so a client that connected before the app last launched sends traffic all day and never registers as evidence. Measured: Claude Code kept one connection across several restarts of the app and appeared only in `legacyBareRequests`, leaving the verdict at `unknown` no matter how many tools it called. `unknown` therefore means *both* "nothing has connected" and "a legacy client is actively using the endpoint over a connection older than this launch", which are very different facts. **To evaluate the condition, restart the client (or its MCP connection) while the app is running, then re-read** — exercising the client is not enough. The counters themselves are verified working end to end: a synthetic `initialize` flips the verdict to `blocked` and names the client, a `_meta`-bearing request registers as modern.

   The separation is the load-bearing part. "Legacy" covers two facts: an `initialize` handshake, which only the old revision has and which therefore *proves* an old client exists, and a **bare request** that declared no era at all and fell back — a stripped header or a hand-typed curl looks identical to an old client. Counted together, the number would never reach zero, this condition would never fire, and the tax would stay while looking measured. So `legacyBareRequests` is reported and deliberately not read as evidence.

Until then the era stays, and this is the paragraph to update — with the measurement — rather than a judgement call at the time.

Deliberately **not** on the official Swift SDK: as of 0.12.1 it caps at `2025-11-25`, is pre-1.0, has no `2026-07-28` work in flight, and carries open cross-request-leak and hang bugs in its stateless HTTP transport — adopting it would *lower* the revision Loom speaks. Revisit at SDK 1.0 + `2026-07-28`.

**The control plane is write-capable, so it is also browser-hardened — done (0.0.9).** Loopback + token-optional means a *web page* is "local" too: any site can `fetch` `127.0.0.1:9092`. A request carrying `Origin` is refused `403`, and one whose Content-Type isn't `application/json` is refused `415` — the latter load-bearing, because `application/json` is not CORS-safelisted, so a cross-site `fetch` must pass a preflight this endpoint fails. Without them a page could POST `text/plain` with no preflight and fire write tools; the response is unreadable cross-origin, but the write already happened.

## Embeddable engine (library reuse)

A second, non-GUI operator has appeared alongside MCP: Loom's capture engine now ships as SPM library products (`LoomProxyCore` + `LoomSharedModels`), and an external host drives `ProxyEngine` directly instead of running its own proxy. The first consumer is [Reticle](https://github.com/KQAR/Reticle), which runs the engine loopback, subscribes to `flowStream()`, and republishes exchanges into its own evidence stream — so "Loom as a backend for another tool" is now a real shape, not the deferred "mitmproxy/whistle backends" one.

**Already shipped for this track:** the `LoomProxyCore` / `LoomSharedModels` products **and matching target names** (root `Package.swift` coexisting with Tuist; the former generic `ProxyCore`/`SharedModels` targets were renamed so a consumer never imports a colliding generic name), `ProxyEngine(persistFlows:)` for embedders that own their storage, mock-model parity (base64/binary mock bodies + host/query/exact match predicates, with tolerant decode), a **configurable bind host** (`ProxyEngine.start(port:host:)`, loopback default) for real-device Wi-Fi/LAN capture, **atomic `setRules([TrafficRule])`** that degrades gracefully (applies the valid rules and reports the rejected ones, instead of all-or-nothing) for one-shot external rule-set sync, **opt-in blind-tunnel observation** (`ProxyEngine.start(observeTunnels:)`) that records an un-decrypted `CONNECT` as a flow (marked by the `CONNECT` method) so embedders can surface HTTPS activity they didn't MITM, and **CA export to a caller-chosen directory** (`ProxyEngine.exportCA(toDirectory:pemName:derName:)`) writing both PEM and DER in one call.

**Versioned releases — done.** The `v*` tags that drive the app's release workflow double as the library's SemVer tags, so a consumer pins `.package(url: …, from: "0.0.5")` instead of a path or branch. One tag for both on purpose: the engine and the app ship from the same commit, and a second version line would only invite them to drift. The root `Package.resolved` stays **uncommitted** (gitignored) — it's a library, so the consumer's resolution wins; `Tuist/Package.resolved` is committed because that one pins the app's own build. See [`.claude/skills/embed-engine/SKILL.md`](.claude/skills/embed-engine/SKILL.md).

**Flow-observer hook — done** (listed as a gap longer than it was one): `FlowObserving` is a public protocol in `SharedModels`, wired through `ProxyEngine(persistFlows:capacity:observer:)` and `FlowStore`'s single broadcast point, so a host that owns its storage is pushed every insert/update instead of double-bookkeeping off `flowStream()`. Covered by `FlowObserverTests`.

## Still Deferred

Windows/Linux, iOS device capture, team/shared sessions, mitmproxy/whistle backends, Web3/RPC inspectors, an in-app LLM assistant (Loom is MCP-first; the agent lives in the user's own client).
