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
- Breakpoints — **done**: `arm_breakpoint` (match reuses `RuleMatch`; pause request and/or response) → held exchange surfaces in `list_pending` → `resume` with edits (method/url/status/headers/body) or `abort`. Poll model (MCP has no server push). Implemented as `BreakpointForwarder`, the outermost `UpstreamForwarding` decorator, backed by a lock-based `BreakpointStore` that parks the exchange on a continuation; non-matching traffic (incl. streaming) is delegated untouched, and an unattended hold auto-proceeds after a timeout so a client can't hang forever. Not persisted (a held exchange holds a live connection open).
- **Write-action safety**: the MCP control plane binds loopback-only (not the LAN-exposed proxy port) and every write is recorded in a durable audit trail; write tools act directly, with no approval gate (owner decision — see [`INTERACTION.md`](INTERACTION.md)).
- **Rule-model authoring surfaces — done.** The model has exact-match, host/query predicates, and base64 (binary) mock bodies. The `set_rule` MCP schema exposes `is_exact`/`host_pattern`/`query`/`body_base64`, so agents can author them (round-tripped in `list_rules`). The SwiftUI Rule editor now surfaces the same set: an exact-match (`=`) toggle beside the regex toggle (mutually exclusive), a collapsible **Match conditions** group (host glob + query key/value predicates), and a **Binary (base64)** mock-body mode — all round-tripped through `RuleDraft` so editing an agent-authored rule no longer silently drops them.

### M4 — Protocol breadth

- HTTP/2 (`swift-nio-http2`), WebSocket frame capture, GraphQL-aware inspector — **done**.
- Persistent store — **done** (SQLite, not GRDB): completed flows persist to `~/Library/Application Support/com.loom/flows.sqlite` and reload on launch; HAR **export** ships (`export_har`). HAR *import* and redacted evidence bundles remain open.
- Stream request bodies — **done**: uploads no longer buffer whole in memory. The request handlers bridge inbound body chunks into a back-pressured async stream (`RequestBodyBridge`, built on `NIOThrowingAsyncSequenceProducer` + a high/low-watermark strategy driving `channel.read()` with `autoRead` paused), and `NIOStreamingForwarder` relays chunks awaiting each flush so a slow upstream back-pressures the client — in-flight bytes stay bounded to the watermark, not the body size. Forwarding starts on the request head (lower latency) instead of after the last byte. A capped `RequestBodyCapture` tees the body for the inspector. Pure passthrough streams; a request-body-mutating rule / short-circuit / matching breakpoint buffers (`RequestBody.collect()`). Applies to **both HTTP/1.1 and HTTP/2** — the stream starts lazily on the first body chunk, so an h2 DATA body with no Content-Length streams too, and the bridge's `read()` replenishes the h2 flow-control window. WebSocket was already streamed (a separate byte-transparent frame splice, never buffered). (There was never a real 413 cap — this replaces unbounded buffering with bounded streaming.)

### M5 — Operability, quality & correctness (in progress)

Hardening the AI-operated loop for sustained real use. The operator is an agent with no human watching each step, so failures must be **bounded** and **observable**.

- **Flow-store durability & bounds — done.** Completed flows flush on quit; in-flight flows are finalized as `interrupted` rather than silently lost. The in-memory ring and the UI flow list are count-bounded, and the list surfaces when it has dropped older flows (no silent truncation). Bodies live **out-of-line**: SQLite stores them in dedicated BLOB columns (list/boot reads stay body-free), the engine ring drops the oldest *persisted* flows' bodies once over a 64 MB budget and re-hydrates on demand, and the UI holds metadata only — fetching a body when a flow is opened. Bounds the three RAM/disk sinks a big or large-body capture would otherwise blow up.
- **Dev infra — done.** The whole test suite runs on **Swift Testing** (XCTest retired); `tuist install` uses the **SwifterPM** resolver (content-addressable, sub-second warm resolves, worktree-friendly); the SPM C-shim targets are static frameworks so clean/`tuist run` builds don't hit the CNIODarwin "Copy Module Map" cycle.
- **Logging & audit trail — audit log done; fail-open error logging next.** The MCP write surface (replay / rules / breakpoints / ssl-scope / har) now records a durable **audit log of write actions** — the choke point is `MCPToolExecutor.call`, entries persist to `audit.sqlite` (row-capped, survives relaunch), and the trail is surfaced to the supervising human in the main-window **sidebar → Audit** panel and to an agent via the `get_audit_log` MCP read tool. Reads are never logged; a test pins the audited set to the "write action"-marked definitions so a write can't slip past. **Still next:** error-level logging on the fail-open paths (corrupt CA, dropped persistence write, rule-apply errors). `os.Logger` stays; a pluggable backend waits until a non-Apple embedder needs it.
- **Correctness guarantees — next.** Name the invariants that, if violated, corrupt what the agent believes — one write path, body hydration, single rule choke point, breakpoints always release, replay produces a linked flow — and back each with a test. Add **Thread Sanitizer** to CI (the Swift-5 NIO handlers are `@unchecked Sendable`), and fault-injection tests on the fail-open paths (paired with the logging above).

## Structured Channel — decided

MCP over loopback HTTP is the transport, effective M1:

- The app hosts a JSON-RPC endpoint at `127.0.0.1:<port>/mcp`; the `loom-mcp` bridge forwards stdio JSON-RPC from AI clients (Claude Desktop, Cursor) to it.
- Auth is a per-launch bearer token written to `~/Library/Application Support/com.loom/mcp-handshake.json` (mode `0600`).
- The domain model (`Flow`, `ReplayOverrides`, rules) is transport-independent; a Streamable-HTTP/SSE upgrade can replace the bridge without touching it.

## Embeddable engine (library reuse)

A second, non-GUI operator has appeared alongside MCP: Loom's capture engine now ships as SPM library products (`LoomProxyCore` + `LoomSharedModels`), and an external host drives `ProxyEngine` directly instead of running its own proxy. The first consumer is [Reticle](https://github.com/KQAR/Reticle), which runs the engine loopback, subscribes to `flowStream()`, and republishes exchanges into its own evidence stream — so "Loom as a backend for another tool" is now a real shape, not the deferred "mitmproxy/whistle backends" one.

**Already shipped for this track:** the `LoomProxyCore` / `LoomSharedModels` products **and matching target names** (root `Package.swift` coexisting with Tuist; the former generic `ProxyCore`/`SharedModels` targets were renamed so a consumer never imports a colliding generic name), `ProxyEngine(persistFlows:)` for embedders that own their storage, mock-model parity (base64/binary mock bodies + host/query/exact match predicates, with tolerant decode), a **configurable bind host** (`ProxyEngine.start(port:host:)`, loopback default) for real-device Wi-Fi/LAN capture, **atomic `setRules([TrafficRule])`** that degrades gracefully (applies the valid rules and reports the rejected ones, instead of all-or-nothing) for one-shot external rule-set sync, **opt-in blind-tunnel observation** (`ProxyEngine.start(observeTunnels:)`) that records an un-decrypted `CONNECT` as a flow (marked by the `CONNECT` method) so embedders can surface HTTPS activity they didn't MITM, and **CA export to a caller-chosen directory** (`ProxyEngine.exportCA(toDirectory:pemName:derName:)`) writing both PEM and DER in one call.

**Gaps to close (surfaced by the Reticle integration):**

- **Versioned releases.** Publish SemVer git tags so consumers can pin `exact:` / `from:` instead of a path or branch dependency, and document the `Package.resolved` policy for the library.
- **Flow-observer hook (nice-to-have).** Embedders consume `flowStream()` and re-persist into their own store; a lightweight observer/sink protocol could spare hosts that own storage the double bookkeeping.

## Still Deferred

Windows/Linux, iOS device capture, team/shared sessions, mitmproxy/whistle backends, Web3/RPC inspectors, an in-app LLM assistant (Loom is MCP-first; the agent lives in the user's own client).
