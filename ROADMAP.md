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

### M2 — HTTPS interception (interception done; privileged helper scaffolded)

- **Done, tested**: P-256 root CA (Keychain-persisted, in-memory store for tests); per-host leaf certificates signed on demand and cached as TLS server contexts. CONNECT is MITM-decrypted — TLS terminated with the minted leaf, plaintext captured, re-forwarded upstream. SSL-proxying scope list (wildcard include/exclude; `exclude` = pinned/pass-through). MCP gains `get_certificate_status`, `get_ssl_scope`, `set_ssl_scope`, `export_ca_certificate`. Proven end-to-end by a NIO-client-through-proxy integration test (`Engine/ProxyCore/Tests`).
- **Scaffolded, unverified**: XPC helper (`SMAppService` daemon `LoomHelper` + app-side `PrivilegedHelperClient`) to install the CA into the system trust store and toggle the system proxy. Hardened design — caller code-signature validation (audit token + `SecRequirement`), Apple-signed-binary checks before exec, precise per-service proxy backup/restore, a crash watchdog that restores connectivity if the app dies, and idle self-exit. Pure logic is unit-tested; runtime needs a signed/notarized app with the daemon embedded + admin approval, so it isn't exercised in CI. Until it's finished, trust the CA manually: `export_ca_certificate` → `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain <path>`.

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

### M7 — Cross-surface parity (next)

M1–M6 grew the agent's surface. This round audited the architecture behind both
surfaces and fixed what had rotted; what it *found* is the phase.

**Done — the drift is now caught by the compiler or by a test** (PRs #103–#110):

- **`ProxyCapability` + `ProxyClientParityTests`** — every `ProxyControlling`
  requirement must be reachable from the human's `ProxyClient` or recorded as a
  deliberate omission with a reason. It found the real one: every breakpoint
  capability was reachable over MCP and absent from the client, so an agent could
  park a live client connection with nothing in the human's surface able to see
  it or let it go. Plumbing closed; **the panel is still missing** (below).
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

**Open — the phase itself.** Adding a capability the *engine* needs is cheap: the
decorator chain and the single choke point absorb it. Adding one that **both the
agent and the human** need is still expensive, and that asymmetry is what M7 is
about:

1. **Breakpoint supervision has no UI.** `BreakpointControlling` is complete in the
   engine, reachable over MCP, and now exposed on `ProxyClient` — but no
   `AppFeature` state or view consumes it. An agent can hold real traffic with
   nothing in the human's panel showing it or releasing it. This is the largest
   standing violation of value #2 (*the human stays in control of risk*), and it is
   UI work, not plumbing.
2. **The parity guard records four deliberate omissions that are really UI gaps** —
   HAR import/export and wholesale `setRules` are agent-only because the window has
   no affordance for them, not because the human shouldn't have them.
3. **A cross-surface capability still costs ~5 edits**: protocol → engine →
   `ProxyClient` field → `liveValue` wiring → feature/view. The guards make a miss
   *loud* rather than silent; they don't make the work smaller. Worth deciding
   whether `ProxyClient` should wrap `any ProxyControlling` directly (losing some
   `@DependencyClient` test ergonomics) before the surface grows again.
4. **Rule authoring still has four representations.** The census keeps them honest;
   it doesn't merge them. If a fifth surface appears (a rule-import format, a
   config file), collapse the codec first.

## Structured Channel — decided

MCP over loopback HTTP is the transport, effective M1:

- The app hosts a JSON-RPC endpoint at `127.0.0.1:<port>/mcp`; the `loom-mcp` bridge forwards stdio JSON-RPC from AI clients (Claude Desktop, Cursor) to it.
- Auth is a per-launch bearer token written to `~/Library/Application Support/com.loom/mcp-handshake.json` (mode `0600`).
- The domain model (`Flow`, `ReplayOverrides`, rules) is transport-independent; a Streamable-HTTP/SSE upgrade can replace the bridge without touching it.

## Embeddable engine (library reuse)

A second, non-GUI operator has appeared alongside MCP: Loom's capture engine now ships as SPM library products (`LoomProxyCore` + `LoomSharedModels`), and an external host drives `ProxyEngine` directly instead of running its own proxy. The first consumer is [Reticle](https://github.com/KQAR/Reticle), which runs the engine loopback, subscribes to `flowStream()`, and republishes exchanges into its own evidence stream — so "Loom as a backend for another tool" is now a real shape, not the deferred "mitmproxy/whistle backends" one.

**Already shipped for this track:** the `LoomProxyCore` / `LoomSharedModels` products **and matching target names** (root `Package.swift` coexisting with Tuist; the former generic `ProxyCore`/`SharedModels` targets were renamed so a consumer never imports a colliding generic name), `ProxyEngine(persistFlows:)` for embedders that own their storage, mock-model parity (base64/binary mock bodies + host/query/exact match predicates, with tolerant decode), a **configurable bind host** (`ProxyEngine.start(port:host:)`, loopback default) for real-device Wi-Fi/LAN capture, **atomic `setRules([TrafficRule])`** that degrades gracefully (applies the valid rules and reports the rejected ones, instead of all-or-nothing) for one-shot external rule-set sync, **opt-in blind-tunnel observation** (`ProxyEngine.start(observeTunnels:)`) that records an un-decrypted `CONNECT` as a flow (marked by the `CONNECT` method) so embedders can surface HTTPS activity they didn't MITM, and **CA export to a caller-chosen directory** (`ProxyEngine.exportCA(toDirectory:pemName:derName:)`) writing both PEM and DER in one call.

**Versioned releases — done.** The `v*` tags that drive the app's release workflow double as the library's SemVer tags, so a consumer pins `.package(url: …, from: "0.0.5")` instead of a path or branch. One tag for both on purpose: the engine and the app ship from the same commit, and a second version line would only invite them to drift. The root `Package.resolved` stays **uncommitted** (gitignored) — it's a library, so the consumer's resolution wins; `Tuist/Package.resolved` is committed because that one pins the app's own build. See [`.claude/skills/embed-engine/SKILL.md`](.claude/skills/embed-engine/SKILL.md).

**Flow-observer hook — done** (listed as a gap longer than it was one): `FlowObserving` is a public protocol in `SharedModels`, wired through `ProxyEngine(persistFlows:capacity:observer:)` and `FlowStore`'s single broadcast point, so a host that owns its storage is pushed every insert/update instead of double-bookkeeping off `flowStream()`. Covered by `FlowObserverTests`.

## Still Deferred

Windows/Linux, iOS device capture, team/shared sessions, mitmproxy/whistle backends, Web3/RPC inspectors, an in-app LLM assistant (Loom is MCP-first; the agent lives in the user's own client).
