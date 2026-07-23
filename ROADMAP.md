# ROADMAP.md

Single source of truth for Loom's **positioning** and **iteration order**. When a scope or prioritization question arises, this doc wins over legacy assumptions in code or older notes. The user-facing shape of these phases is specified in [`INTERACTION.md`](INTERACTION.md); the visual system in [`DESIGN.md`](DESIGN.md).

## Positioning

Loom is **not** another Charles/Proxyman clone that adds a chat box. Human-first traffic inspection with an AI reading pane is table stakes — existing tools already ship that.

Loom is an **AI-operable debugging proxy**: a macOS status-bar app whose primary operator is an AI agent talking MCP, and whose human owner supervises from the menu bar. Its job is to let an agent **close the debugging loop without a GUI** — capture, inspect, *modify, replay, diff* — and to keep the human in control of the actions that touch real traffic.

Value hierarchy (higher beats lower when they conflict):

1. **AI can act, not just read.** The MCP surface exposes write actions (replay, rules, breakpoints), not only queries. This is the moat; read-only MCP is not.
2. **The human stays in control of risk.** Write actions are scoped and, when destructive, gated. An agent can debug freely inside its allowed scope and never surprise the owner outside it.
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

- `create_rule` (map local / map remote / block / rewrite header / throttle), `diff_flows`.
- Breakpoints: `arm_breakpoint` → held request surfaces in `list_pending` → `resume` with edits (poll model; MCP has no server push).
- **Scoped-write guardrail**: every write tool is bounded by an allow-list of hosts; destructive actions require human confirmation (see [`INTERACTION.md`](INTERACTION.md)).
- **Rule-model authoring surfaces.** The model gained exact-match, host/query predicates, and base64 (binary) mock bodies (added for embedders — see below), but `create_rule`/`update_rule`'s `matchSchema` and the Rule editor UI still only offer `urlPattern`/`isRegex`/`methods` and a text mock body. Wire `isExact`, `hostPattern`, `query`, and `bodyBase64` through the MCP schema and the editor so humans and agents can author them too.

### M4 — Protocol breadth

- HTTP/2 (`swift-nio-http2`), WebSocket frame capture, GraphQL-aware inspector.
- Persistent store (GRDB) with HAR import/export and redacted evidence bundles.
- Stream request bodies — responses already stream chunk-by-chunk; large request uploads still buffer in memory (capped, 413 on overflow).

## Structured Channel — decided

MCP over loopback HTTP is the transport, effective M1:

- The app hosts a JSON-RPC endpoint at `127.0.0.1:<port>/mcp`; the `loom-mcp` bridge forwards stdio JSON-RPC from AI clients (Claude Desktop, Cursor) to it.
- Auth is a per-launch bearer token written to `~/Library/Application Support/com.loom/mcp-handshake.json` (mode `0600`).
- The domain model (`Flow`, `ReplayOverrides`, rules) is transport-independent; a Streamable-HTTP/SSE upgrade can replace the bridge without touching it.

## Embeddable engine (library reuse)

A second, non-GUI operator has appeared alongside MCP: Loom's capture engine now ships as SPM library products (`LoomProxyCore` + `LoomSharedModels`), and an external host drives `ProxyEngine` directly instead of running its own proxy. The first consumer is [Reticle](https://github.com/KQAR/Reticle), which runs the engine loopback, subscribes to `flowStream()`, and republishes exchanges into its own evidence stream — so "Loom as a backend for another tool" is now a real shape, not the deferred "mitmproxy/whistle backends" one.

**Already shipped for this track:** the `LoomProxyCore` / `LoomSharedModels` products (root `Package.swift` coexisting with Tuist), `ProxyEngine(persistFlows:)` for embedders that own their storage, mock-model parity (base64/binary mock bodies + host/query/exact match predicates, with tolerant decode), a **configurable bind host** (`ProxyEngine.start(port:host:)`, loopback default) for real-device Wi-Fi/LAN capture, and **atomic `setRules([TrafficRule])`** for one-shot external rule-set sync.

**Gaps to close (surfaced by the Reticle integration):**

- **Optional blind-tunnel observation.** The engine emits a flow only for traffic it decrypts; a consumer that wants a record of un-decrypted `CONNECT` tunnels has nothing to surface. Offer an opt-in "tunnel observed" event so embedders can show HTTPS activity they didn't MITM.
- **CA export ergonomics.** Expose the root CA as both DER and PEM to a caller-chosen directory. Today `exportCACertificate()` writes PEM to a fixed default path and `caCertificateDER()` returns bytes; an embedder installing the CA on a device needs both forms where its trust flow looks.
- **Distinct module names.** The targets are `ProxyCore` / `SharedModels`, so a consumer `import`s those generic names. Rename to `LoomProxyCore` / `LoomSharedModels` (or add module aliases) to avoid collisions in a larger dependency graph.
- **Versioned releases.** Publish SemVer git tags so consumers can pin `exact:` / `from:` instead of a path or branch dependency, and document the `Package.resolved` policy for the library.
- **Flow-observer hook (nice-to-have).** Embedders consume `flowStream()` and re-persist into their own store; a lightweight observer/sink protocol could spare hosts that own storage the double bookkeeping.

## Still Deferred

Windows/Linux, iOS device capture, team/shared sessions, mitmproxy/whistle backends, Web3/RPC inspectors, an in-app LLM assistant (Loom is MCP-first; the agent lives in the user's own client).
