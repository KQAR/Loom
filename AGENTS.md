<!-- CLAUDE.md is a symlink to this file. Always update AGENTS.md, not CLAUDE.md. -->
<!-- Rule: every edit to this file must make it MORE CONCISE or MORE USEFUL. Never add fluff. -->

# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Loom is a personal macOS 14+ app: an **AI-operable debugging proxy** that lives in the status bar. It captures HTTP/HTTPS traffic like Charles/Proxyman, but its primary operator is an AI agent talking **MCP** — and, this is the differentiator, the MCP surface exposes **write actions** (replay, rules, breakpoints), not just read queries. The agent closes the debug loop (capture → modify → replay → diff) with no GUI; the human supervises from the menu bar and gates risky writes.

[`ROADMAP.md`](ROADMAP.md) is the single source of truth for positioning and iteration order. Read it before making scope or prioritization decisions.

**Stack**: SwiftUI + TCA, Tuist, Swift 6 (NIO modules Swift 5), SwiftNIO, SPM, macOS 14+.

**Fail-open logging**: the engine fails open by design (a corrupt CA regenerates, an unreadable rules file starts empty, a bad SSL scope disables interception) — but never silently. Those paths log at error level through `Log` (`proxy`/`tls`/`forward`/`store`/`websocket`/`audit`/`rules`); read them with `log stream --predicate 'subsystem == "com.loom"'`.

## Design System

Three docs govern the product; each wins over code in its domain:

- [`ROADMAP.md`](ROADMAP.md) — positioning and iteration order
- [`DESIGN.md`](DESIGN.md) — visual system for the **status-bar panel** (the whole human surface) + the optional Detail viewer, derived from Apple's HIG, **not** from existing code
- [`INTERACTION.md`](INTERACTION.md) — interaction architecture: the AI-operates / human-supervises inversion, the status-bar panel as the one surface, write-action guardrails

**UI is status-bar-first (DESIGN/INTERACTION v3).** The human surface centers on the menu-bar panel — now a compact **config & control console** (`PanelView`): a header with the proxy address + on/off switch and a capture dot (green recording · yellow paused · grey off), state rows (Connect Device, System Proxy, HTTPS, Client Certificates, Rules — the last two conditional), and a footer (version · wordmark · Quit). The main window (`MainView`) is the working surface — a request table + tabbed inspector — opened at launch. Both are driven by the one `AppFeature` store. Any view that conflicts with the specs is the thing to fix; don't propagate old styling.

When a current view conflicts with these specs, the view is wrong: refactor toward the spec, never propagate legacy styling. Read DESIGN.md and INTERACTION.md before writing or reviewing any view code.

## Legal boundary (read once)

Loom is a clean-room implementation. Studying open-source proxies to learn *what* to build and *what interfaces* to expose is fine, but **never copy third-party source into this repo, and never write code by transcribing someone else's** — especially copyleft (AGPL/GPL) projects. Learn MITM/NIO specifics from Apple's swift-nio examples (Apache-2.0) and mitmproxy docs. Ideas and interface shapes are fair game; literal code is not.

## Build Commands

```bash
tuist install                 # Resolve SPM dependencies
tuist generate                # Generate Loom.xcworkspace
# Build the app (`tuist build` is deprecated; `tuist xcodebuild` wraps xcodebuild).
# The `-workspace` flag is REQUIRED — with only `-scheme` xcodebuild picks the wrong
# project and fails to resolve SPM modules (e.g. "Unable to find module dependency:
# 'ComposableArchitecture'"). Products land in the same DerivedData either way.
tuist xcodebuild -workspace Loom.xcworkspace -scheme Loom -configuration Debug -destination 'platform=macOS' build
tuist clean                   # Clean
tuist edit                    # Edit Tuist manifests in Xcode

# Direct xcodebuild (CI / scripted):
xcodebuild -workspace Loom.xcworkspace -scheme Loom -configuration Debug -destination 'platform=macOS' build
xcodebuild -workspace Loom.xcworkspace -scheme loom-mcp -destination 'platform=macOS' build

# Consume the engine as a plain SPM library (no Tuist / Xcode needed):
swift build                   # builds LoomSharedModels + LoomProxyCore from the root Package.swift

# Run every test bundle exactly the way CI does (all 5 targets, one scheme):
tuist generate --no-open      # REQUIRED first — see the false-green note below
xcodebuild test -workspace Loom.xcworkspace -scheme Loom-Workspace -destination 'platform=macOS' \
  -resultBundlePath /tmp/Tests.xcresult
scripts/assert-tests-ran.sh /tmp/Tests.xcresult ProxyCoreTests AppFeatureTests MCPServerTests \
  PrivilegedHelperClientTests SharedModelsTests
```

Tuist is pinned to **4.202.5** in `mise.toml` — do not downgrade (see Known Issues).

**Never trust `** TEST SUCCEEDED **` on its own.** `Project.swift` lists sources by glob, and the
glob is expanded at *generate* time into the `.xcodeproj` — so a test file added since the last
`tuist generate` isn't in the target, and xcodebuild reports success having run **zero tests**. Same
if a bundle drops out of the scheme's test action. `scripts/assert-tests-ran.sh` is the actual pass
condition: it reads the result bundle and fails unless every named bundle ran and nothing failed.

## CI

`.github/workflows/ci.yml` gates every PR and every push to main:

| Job | What it protects |
|-----|------------------|
| **Build & test** | The whole Tuist graph compiles; all five test bundles run (`Loom-Workspace` scheme) and pass, verified through `assert-tests-ran.sh`. |
| **SPM library** | `swift build` + `swift test` on the root `Package.swift` — the embeddable `LoomProxyCore`/`LoomSharedModels` graph resolves without Tuist (this is what Reticle consumes, and it can rot silently otherwise). |
| **Thread Sanitizer** | `ProxyCoreTests` under TSan — the only check on the Swift-5 `@unchecked Sendable` channel handlers. Baseline is clean (229 instrumented tests, zero races). **Can't be reproduced locally on macOS 26**: TSan's runtime segfaults during its own init there (an empty `int main(){}` reproduces it), so the job treats a run that didn't complete as inconclusive-and-failing rather than "no races found". |

`.github/workflows/release.yml` is separate and tag-driven (see Release & Auto-Update).

**A red run on `main` is not automatically a regression.** Re-run the failed job before diagnosing. The breakpoint-timing flakes are now **fixed rather than tuned**: `BreakpointTests` waits on the `pendingStream()` announcement instead of spinning `Task.yield()`, proves watchdog cancellation by awaiting the watchdog and checking `BreakpointStore.timeoutResolutions` instead of sleeping past its deadline, and carries a suite-level `.timeLimit` so a genuine stall fails by name instead of hanging the run. If one of those goes red now, treat it as real — and it happened: `resolvingAHold_cancelsTheTimeoutWatchdog` went red under TSan (only there, and only on the `main` run) because `hold` announced a parked exchange *before* arming its watchdog, so "announced" did not imply "fully parked". TSan slows the tail of `hold` enough to lose that race. `hold` now arms and attaches the watchdog before announcing (and skips the announcement entirely if the hold was already resolved, which would hand a waiter something it can't act on), and `anAnnouncedHold_alreadyHasItsWatchdogArmed` pins the ordering through the `willAnnounceParked` seam rather than by reading state after an announcement — that reading passes under either ordering on a fast machine, which is exactly how the bug shipped. What is still genuinely flaky: `HTTP2InterceptionTests` (see the h2 note below) and infrastructure — a job the hosted runner never picks up fails with "not acquired by Runner", which is not your change. Note this is **not** the documented h2 flake below: that one is the *upload* test and prints byte counters. Also note the PR check and the `main` check are separate runs, so a green PR does not mean `main` went green — look at both before tagging a release.

## Scope

**In scope now (M1 + M2 interception, done)**: HTTP capture proxy, HTTPS MITM interception (on-demand P-256 CA + per-host leaf certs, TLS termination, SSL-proxying scope), in-app MCP server + `loom-mcp` bridge, read tools + write tools (`replay_flow`, `set_ssl_scope`, `export_ca_certificate`), menu-bar shell + Inspector window.
**In scope now also (M3, done)**: traffic rules — structured `TrafficRule` model (no text DSL; whistle-inspired semantics only) with optional **groups** (batch enable/disable, scenario switching), applied for all paths in one choke point (`RuleApplyingForwarder` decorating `UpstreamForwarding`), persisted in UserDefaults (`com.loom.rules`), exposed as 7 MCP tools + UI (sidebar Rules panel, row context-menu rule templates, rule-hit indicators, `appliedRules` audit on flows). Plus **`diff_flows`** (structured request/response diff, closing the capture→modify→replay→diff loop) and **breakpoints** — a `Breakpoint` (reusing `RuleMatch`) holds matching traffic mid-flight via `BreakpointForwarder` (outermost `UpstreamForwarding` decorator) + a lock-based `BreakpointStore` that parks the exchange on a continuation; held exchanges surface via `list_pending` (poll) or `wait_for_pending` (blocking, fed by `BreakpointStore.pendingStream()`), released with `resume` (edit or abort). Breakpoints are **not persisted** (a held exchange holds a live connection). **Owner decision: no approval mode** — all MCP write tools act directly; INTERACTION.md's approval-card gating is not implemented for rules/breakpoints by design.
**In scope now also (M6, done — cheaper agent loops)**: content search (`header_contains`/`body_contains`), blocking waits (`wait_for_flow`/`wait_for_pending`) instead of poll loops, aggregation (`get_stats`), batch replay (`replay_flow(count:concurrency:)`), origin-scoped rules/breakpoints (`RuleMatch.sourceApp`/`deviceIP`, threaded via `forwardStream(…, origin:)`, fail-closed on unattributed traffic), routing visibility + control (`get_proxy_status.systemProxy`, `set_system_proxy` through the app-injected `SystemRoutingControlling`), and HAR both ways (`import_har`, `export_har(redact:)`).
**In scope now also (M8, in progress — capture reach)**: a **SOCKS5 listener** (`SOCKSServer` + `SOCKSConnectionHandler`, bound one port above the HTTP proxy and reported as `ProxyStatus.socksPort` / `get_proxy_status.socksPort`) for the clients the HTTP proxy port can never see: anything honouring only `ALL_PROXY`/a SOCKS field, and anything that isn't HTTP at all. SOCKS names a destination *before* the client sends a byte, so the capture strategy is decided by sniffing the first bytes (`ProtocolSniff`: TLS record → MITM if in SSL scope, HTTP request line → cleartext capture, anything else incl. h2c prior knowledge → byte-transparent relay), not from the port number — the whole point is the traffic on non-standard ports. Both entry points install the *same* stack through `MITMPipeline`, because the intercepted handler names are load-bearing for the WebSocket upgrade and two copies is how one entry point rots. What this does **not** fix: a process that ignores every proxy setting (that needs transparent/pf redirection, deliberately not planned — see ROADMAP). Plus **mutual TLS**: `ClientCertificate` (PKCS#12 + passphrase, scoped by host glob) held in `ClientCertificateConfig` (`client-certificates.json`, 0600, validated on the way in, one `NIOSSLContext` cached per identity and dropped on any mutation) and consulted by `NIOStreamingForwarder` per upstream host, so an origin that *demands* a client certificate can be captured at all — without one the handshake fails and there is no exchange to record. Exposed as `list_client_certificates` / `set_client_certificate` / `delete_client_certificate`, wired into `ProxyClient` (which credential Loom presents to a third party is the human's to see and revoke) and surfaced in the **status-bar console** as a collapsed **Client Certificates** row under HTTPS (`ClientCertificatesCard`: list + `.fileImporter` add + confirmed delete). It is a row in the config console, **not** a sidebar panel: Rules / Breakpoints / Audit exist for activity that needs supervising *while it happens*, and an identity is installed once and then sits for months. The row appears while SSL is on **or** whenever an identity exists — the second half is what stops an agent's install from being invisible when interception happens to be off — and its detail reads "N need attention" when any identity is expired or unreadable, because both fail a handshake exactly like a missing one. Two rules ride along: a **configured-but-unloadable** identity throws rather than connecting without it (the error must name the identity, not the origin), and the audit trail **redacts** `pkcs12_base64` / `passphrase` (`MCPToolExecutor.redactedArgumentNames`) — supervision records the action, not the key.
**Next (ordered — see [`ROADMAP.md`](ROADMAP.md))**: finish M2 (privileged helper for system-trust install + system-proxy — an unverified scaffold, blocked on Developer ID signing/notarization); the breakpoint supervision gap is **closed**: `BreakpointsFeature` mirrors armed + held state from the engine (seeded at boot, followed via `pendingBreakpointStream`, re-synced after every write and by a slow poll that runs *only* while something is held — a hold can also resolve without a decision, on client hangup or the watchdog), the main window has a **sidebar → Breakpoints** panel (`BreakpointsPanelView`: held exchanges lead, each releasable/abortable inline; armed breakpoints below, disarmable), and the status-bar panel grows an orange **Breakpoints** row — only when something is armed or held — that names the held requests and jumps to that panel. Editing a held exchange stays agent-only (`resume` over MCP with the full `BreakpointEdit`); the human's two decisions are proceed-unmodified and abort, deliberately, so there is no second write path onto the same continuation.

**Parity of the two control surfaces is now an invariant, not a habit.** `ProxyCapability` (next to `ProxyControlling` in SharedModels) enumerates every requirement of the engine's control surface, and `ProxyClientParityTests` switches over it exhaustively: adding a protocol requirement means adding a case, which fails to compile until it is either wired to a `ProxyClient` endpoint or recorded as `.deliberatelyAbsent("reason")`. The MCP side needs no such guard (it reaches the protocol directly, so the compiler keeps it complete); the hand-written TCA mirror is the side that drifted, which is how the breakpoint gap opened in the first place.
**Deferred**: Windows/Linux, iOS device capture, team sessions, in-app LLM assistant.

## Core Concepts

### Domain Model (`SharedModels`)

- **Flow**: one captured or replayed request/response exchange. Carries `CapturedRequest`, optional `CapturedResponse`, timing (`startedAt` → `firstByteAt` → `completedAt`, giving `ttfbMS` = server think-time and `receiveMS` = body transfer, so "why is this slow" is answerable; HAR maps them to `timings.wait`/`receive`, with `-1` for phases Loom doesn't measure), `error`, `replayedFrom` (set when produced by a replay), `sourceApp` (local process, resolved via one cached libproc `localPort→pid` sweep per burst — loopback peers only, since a LAN device has no local pid and its remote port could collide with a local socket's) and `sourceDevice` (originating device: this Mac or a LAN device, keyed on remote IP, typed from User-Agent via `UserAgentParser`).
- **HeaderPair**: headers are an *ordered list*, not a dictionary — order and duplicates are preserved as seen on the wire.
- **ReplayOverrides**: how a flow is mutated before re-send (method / url / set+remove headers / body).
- **ProxyControlling** = `FlowProviding` (read) + `FlowReplaying` (write) + TLS / capture / rules / breakpoints / audit: the protocol the engine implements and both the TCA client and MCP server consume. `ProxyCapability` enumerates its requirements so the hand-written TCA mirror can be checked against it (see the parity note in Scope).
- **FlowComparison**: what changed between two flows (scalars, header add/remove/change with repeats preserved, LCS line diff with a 400-line cap, binary/oversize fallbacks, "one side never answered"). **One** definition, rendered two ways — as JSON by `diff_flows`, as rows by the Inspector's diff pane. They used to disagree, which meant the agent and the human supervising it were reading different answers to the same question. A new rule about what counts as a difference goes here, never in a renderer.

### Runtime Flow

```
Client (curl -x / system proxy)   ──▶ ProxyCore HTTP  :9090 ──┐
Client (ALL_PROXY / SOCKS field)  ──▶ ProxyCore SOCKS5 :9091 ──┴─capture─▶ FlowStore (ring + AsyncStream)
                                        │
                 ┌──────────────────────┴───────────────────────┐
          ProxyClient (TCA)                               MCPServer :<port>/mcp
          drives Inspector UI                             ◀── loom-mcp bridge ◀── AI client
                 └──────── same ProxyEngine.shared, one write path ────────┘
```

Both the UI and the AI act through the **same** `ProxyEngine.shared` — "AI modifies a request" and "human clicks Replay" run identical code. Never fork a second write path.

### The AI link

Two ways in, both hitting the **same** in-process MCP server (all tools + state live in the app, sharing memory with the capture store):

- **HTTP direct (Claude Code / Cursor plugin)** — the app serves MCP over HTTP on a **fixed loopback port `127.0.0.1:9092`** (`MCPServer.defaultPort`). The `loom` plugin's root `.mcp.json` points a `type: http` server at `http://127.0.0.1:9092/mcp`; Claude/Cursor just connect — they do **not** launch or build anything, so a random-port bridge is unnecessary. Loopback requests need **no token** (`authorized()` allows a missing `Authorization` header on the loopback-only endpoint); a token, when sent, must still match. **Local trust is why a browser must be kept off this endpoint**, and two checks in `MCPHTTPHandler` do it: a request carrying an `Origin` header is `403`d (no real client is a web page), and a request whose Content-Type isn't `application/json` is `415`d — the latter is load-bearing, because `application/json` is not CORS-safelisted, so a cross-site `fetch` has to pass a preflight this endpoint fails. Without them any site could POST `text/plain` at 127.0.0.1:9092 with no preflight and fire write tools; the response is unreadable cross-origin, but the write already happened. The app owning the server means: if the tools are unreachable, the app isn't running — the skill tells the agent to install/launch Loom rather than fabricate data.
- **stdio bridge (Claude Desktop / other stdio-only clients)** — `loom-mcp` is a tiny **stdio↔HTTP bridge** with no business logic. The client launches it; it reads `~/Library/Application Support/com.loom/mcp-handshake.json` (`{token, port}`, mode `0600`) and forwards each JSON-RPC line to the app's HTTP endpoint with `Authorization: Bearer <token>`. Still works because the app writes the handshake with whatever port it bound (now the fixed `9092`).

**Two protocol revisions, one endpoint (`MCPProtocol`).** Loom serves **`2026-07-28`** ("modern": no handshake, per-request `_meta` carrying protocol version + client capabilities, `MCP-Protocol-Version`/`Mcp-Method`/`Mcp-Name` mirrored into headers and checked against the body, `resultType` on every result, `ttlMs`+`cacheScope` on `tools/list`, `server/discover`) **and `2025-06-18`** ("legacy": `initialize`). The era is decided **per request from the body** — `_meta` protocol version present → modern; `initialize` → legacy; a bare request → legacy — with the header consulted only to catch a modern-claiming header over a body with no `_meta`, which is a `-32020 HeaderMismatch` rather than something to serve quietly.

Dual-era is not politeness, it's the only working direction: a modern client probes and falls back, a **legacy client cannot fall forward**, so dropping `2025-06-18` would silently disconnect every client that hasn't rolled over. The other half of that: before this, a modern probe got `200 OK` from the legacy-only server (`tools/list`/`tools/call` share names across eras), so a dual-era client latched "modern" and never fell back — answering `UnsupportedProtocolVersionError` (`-32022`, with `supported`) is what makes renegotiation possible at all. Modern replies also use real HTTP status codes (`400` validation, `404`+`-32601` unknown method, `405` on the removed GET/DELETE verbs); **legacy replies stay on `200` even for errors**, which is what clients served here have always read. `loom-mcp` mirrors body→headers itself, because stdio has no headers and the HTTP side requires them. Loom is **not** on the official Swift SDK: as of 0.12.1 it caps at `2025-11-25`, is pre-1.0, and has open hang/cross-request-leak bugs in its stateless HTTP transport — adopting it would *lower* the revision Loom speaks.

**Plugin packaging.** The repo root doubles as a Claude Code / Cursor plugin (modelled on KQAR/Reticle): `.claude-plugin/` + `.cursor-plugin/` (`plugin.json` + `marketplace.json`, `source: "./"`), a shared root `.mcp.json` (the HTTP server above), and `skills/loom/SKILL.md` documenting the tools + the debug loop. The MCP endpoint stays **loopback-only on its own port** — deliberately NOT the proxy's `9090`, which binds `0.0.0.0` when LAN device connection is on and would otherwise expose the write-capable, token-optional control plane to the whole Wi-Fi.

**Two skill directories, two audiences — they are not duplicates, don't merge them.** `skills/` ships *with the plugin* to its users (`skills/loom/SKILL.md`: the tool surface, the debug loop, and the scrub-before-you-file rules for reporting a Loom bug). `.claude/skills/` is for whoever is *working on this repo* (`release`, `embed-engine`) and is auto-discovered when the project is opened. Moving the latter into `skills/` would ship maintainer procedure — EdDSA key handling included — to every plugin user; moving the former into `.claude/skills/` breaks the plugin, whose skills path is fixed at `<plugin-root>/skills/` (and hard-coded in `.cursor-plugin/plugin.json`). Both stay tracked in git: this file delegates authoritative content to them. Only `.claude/settings.local.json` is ignored.

### MCP Tools

The full tool list — names, kinds, arguments, and the debug loop they compose into — lives in
[`skills/loom/SKILL.md`](skills/loom/SKILL.md) (lazy-loaded) and, authoritatively, in the registry
at `Engine/MCPServer/Sources`. Don't mirror it here; it drifts.

That registry is split by concern: `MCPToolSchemas.swift` is everything `tools/list`
advertises, `MCPToolExecutor.swift` is the state + the `call` dispatch/audit choke point, and
`MCPTools+<domain>.swift` (Environment / Flows / Waits / Replay / HAR / Rules / Breakpoints /
Rendering) holds the handlers. **Adding a tool touches three places** — a definition in the
schemas file, a handler in its domain file, and an entry in `handlers`; plus `writeTools` if it
writes. All three pairings are covered by `MCPServerTests`, so a mismatch fails rather than
silently shipping an advertised-but-undispatchable (or unaudited) tool.

WebSocket flows (ws:// and wss:// via MITM) are captured as a single flow whose frames appear in `get_flow_detail` under `webSocket.messages` (direction/kind/text-or-bytes) and are flagged in `get_recent_flows`. GraphQL POSTs are recognized (`GraphQLParser`); `get_flow_detail` adds a `graphQL` block (kind/operationName/query/variables) and the Inspector shows a GraphQL tab. HTTP/2 is intercepted when the client negotiates ALPN `h2`: the MITM leaf advertises `h2`+`http/1.1`, and each h2 stream is demuxed through the h2↔h1 codec into the same `TLSInterceptHandler` capture path (falls back to http/1.1 otherwise). Completed flows persist to `~/Library/Application Support/com.loom/flows.sqlite` (WAL + `synchronous=NORMAL`, row-capped, an order of magnitude larger than the in-memory ring) and reload on launch. Writes are **batched**: rows queue for a 50 ms window (or 256 rows) and land in one transaction through one reused prepared statement, and the row cap is enforced off a counter (`maxRows + pruneSlack`) instead of a full index scan per write; every read drains the pending batch first, so batching is invisible to callers, and `flush()`/`deinit` drain it so a quit can't lose it. Reads **read through** to it: `FlowStore.flow(id:)` falls back to the row when a flow has aged out of the ring (so `get_flow_detail` / `diff_flows` / `replay_flow` still resolve an id an agent legitimately holds), and `recentHydrated` (the HAR export path) tops up from disk rather than silently returning only what's in memory. Every MCP **write** tool call is recorded in a durable **audit trail** (`~/Library/Application Support/com.loom/audit.sqlite`, row-capped, survives relaunch): the choke point is `MCPToolExecutor.call`, which records an `AuditEntry` (tool, arguments, success/failure, detail) for each tool in `MCPToolExecutor.writeTools` — read tools are never logged. The engine owns an `AuditStore` (actor + fan-out, sibling of `FlowStore`) exposed via `AuditControlling` (`recordAudit` / `recentAuditEntries` / `auditStream`); the supervising human reads it in the main-window **sidebar → Audit** panel (`AuditPanelView`, read-only newest-first timeline), and an agent reads it back via `get_audit_log`. `MCPServerTests` asserts `writeTools` matches the "write action"-marked tool definitions so a write can't silently escape auditing.

Write tools are the reason Loom exists. When adding one, it must be scoped and — if destructive — gated per [`INTERACTION.md`](INTERACTION.md).

### Key Modules

| Module | Layer | Responsibility |
|--------|-------|----------------|
| **SharedModels** | base | `Flow`, `ReplayOverrides`, `FlowQuery`, `FlowComparison`, `ProxyControlling` + `ProxyCapability`, `SSLScope`, `CertificateStatus`, HAR — pure value types, no deps. Ships as a public SPM product, so **keep app-deployment detail out of it** |
| **HelperProtocol** | base | The app ⇄ root-daemon contract only: `LoomPrivilegedHelperProtocol` (XPC), `HelperIdentity` (launchd label, Mach service, caller code requirement), `ProxyServiceState`/`ProxyBackup`/`SystemProxyParsing`. Depended on by `PrivilegedHelperClient` and `LoomHelper` — and by nothing else |
| **ProxyCore** | engine | SwiftNIO proxy, `ProxyEngine` actor, `FlowStore`, CONNECT tunnel, **SOCKS5 listener** (`SOCKSServer`, `SOCKS5` codec, `ProtocolSniff`), **MITM** (`CertificateAuthority`, `TLSInterceptHandler`, `MITMPipeline`, `CAStore`, `InterceptionConfig`), `UpstreamForwarding` |
| **MCPServer** | engine | loopback JSON-RPC HTTP server (fixed port 9092, loopback token-optional), tool registry, handshake writer |
| **ProxyClient** | client | `@DependencyClient` wrapping `ProxyEngine.shared` for TCA |
| **PrivilegedHelperClient** | client | app-side TCA surface over the helper: SMAppService register/approve + XPC (system proxy, CA trust) — **unverified scaffold** |
| **UpdaterClient** | client | `@DependencyClient` over **Sparkle** (`UpdaterCoordinator` owns `SPUStandardUpdaterController`); silent once-a-day probe + user-initiated check, feeds the panel's footer "Update" button — Swift 5 mode |
| **AppFeature** | feature | TCA reducer + status-bar panel (live feed) + optional Detail viewer |
| **Loom** | app | MenuBarExtra entry (panel); boots proxy + MCP server |
| **loom-mcp** | tool | stdio↔HTTP bridge binary |
| **LoomHelper** | tool | root daemon: per-service proxy backup/override/restore, CA trust install/verify, caller + Apple-binary validation, crash watchdog, idle-exit — **unverified scaffold** |

## Architecture

### Layering (dependency direction is one-way)

```
App → AppFeature → ProxyClient → ProxyCore → SharedModels
                    MCPServer  ─────────────▶ SharedModels
```

Features never depend on each other (M1 keeps a single `AppFeature`; split later). Engine modules never depend on TCA.

[`docs/architecture/`](docs/architecture/) holds an interactive map of this graph — nodes/edges/flows as a self-contained HTML page, plus the same data as JSON for an agent. It is a **hand-authored snapshot, not generated from the code**: useful for orientation, but where it and the code disagree the code is right.

### Library reuse (SPM)

The two lowest layers ship as SPM library products (`LoomSharedModels`, `LoomProxyCore`) so any
Swift host can embed the engine without Tuist or the app; `swift build` builds them from the root
`Package.swift`, which coexists with `Project.swift`. Embedding details, zero-retention options and
the flow-emission contract: **`.claude/skills/embed-engine/SKILL.md`** (lazy-loaded).

### Concurrency

- **App / Features / Clients**: Swift 6 language mode, strict concurrency.
- **ProxyCore + MCPServer**: **Swift 5 language mode** (`SWIFT_VERSION=5.0` in `Project.swift`). SwiftNIO's channel model fights Swift 6 Sendable; handlers are `@unchecked Sendable`. Keep NIO code in these two modules; do not leak channel types across the client boundary.
- `ProxyEngine` and `FlowStore` are **actors**; the shared engine is `ProxyEngine.shared`.
- Replay and proxy forwarding use a hand-rolled SwiftNIO upstream client (`NIOStreamingForwarder`, M4) — Loom owns every request header, and `forward` (buffered) plus replay are both **folds over `forwardStream`**, so there is one production path. Requests and responses stream with real back-pressure, bounded in-flight bytes; a rule that must see a whole body (rewrite/mock/block/mapLocal) or a matching breakpoint forces buffering. **A capped capture is never silent** — the true wire size and dropped-frame counts surface in `get_recent_flows` / `get_flow_detail` / HAR / the Inspector. Details: [`Engine/ProxyCore/CLAUDE.md`](Engine/ProxyCore/CLAUDE.md) (auto-loads when working in ProxyCore) and [`Engine/ProxyCore/FORWARDING.md`](Engine/ProxyCore/FORWARDING.md).

### Conventions

- **Side effects**: always through TCA `Effect` — no async work in views.
- **Reducers never touch NIO**: the engine is reached only through `ProxyClient` (`@DependencyClient` + a `DependencyValues` extension).
- **One write path**: UI and MCP both go through `ProxyEngine.shared`. Adding a write must extend `ProxyControlling`, not bypass it.
- **Bundle prefix**: `com.loom` (personal project — no employer branding anywhere).
- **Everything Loom writes to Application Support is owner-only.** Go through `LoomPaths.createSecureDirectory(at:)` (0700, and it tightens a directory that already exists) and `LoomPaths.restrictToOwner(_:)` (0600) — never a bare `createDirectory`. The CA key was always protected this way; `flows.sqlite` and `audit.sqlite` weren't, and they hold whole request/response bodies and every write tool's arguments. The **directory** mode is the load-bearing part, because SQLite creates `-wal`/`-shm` itself and Loom never gets to chmod them at creation. `client-certificates.json` is the strictest case — it holds private keys and their passphrases in cleartext, same threat model as the CA key — and a test pins its mode rather than trusting the writer.
- **A holder that persists off a lock enqueues the write under it.** `RulesConfig` / `InterceptionConfig` snapshot state under a lock and hand the write to a private serial queue *before* unlocking, so disk order matches mutation order; `flush()` drains it, and `ProxyEngine.flushFlows()` calls both on quit. Persisting after unlocking let two concurrent MCP writes land out of order and leave the file holding a stale snapshot — silently, until the next launch. Don't "simplify" it by persisting inside the lock either: `snapshot()` runs on the event loop for every request.
- **UI**: follow [`DESIGN.md`](DESIGN.md) — semantic system colors, text styles, capsule controls. Never inline hex or fixed font sizes.
- **Performance is a hard requirement, not a nice-to-have.** A capture proxy routinely holds tens of thousands of flows with multi-MB bodies; every list and every large-data render must stay smooth at that scale. Rules:
  - **Never render a large/unbounded collection eagerly.** Row-based views use a lazy container — `List`, `Table` (both NSTableView-backed), or `LazyVStack`/`LazyVGrid` in a `ScrollView`. Never `ScrollView { VStack/ForEach over data } }` for a collection that can grow (only for a fixed, small set of blocks).
  - **O(1) upsert.** The flow ring carries an `id -> absolute position` map (`FlowStore.positions`), so the several upserts every exchange performs (pending → completed, per streaming update, per WebSocket frame) are dictionary lookups, not scans of a 2000-element ring on the actor.
  - **Bound what's in memory.** Every in-memory collection has an explicit cap (flow ring/UI list = 2000, audit = 500, favicons = 512, per-host MITM TLS contexts = 512 LRU, app icons via `NSCache`) and the UI honestly surfaces when it dropped items (no silent truncation). The two icon caches were the exceptions until they weren't — `FaviconLoader.icons` stays a dictionary with hand-rolled eviction because `@Observable` can't track an `NSCache`, so a swap there would silently stop views refreshing.
  - **Bodies out-of-line.** List/summary/boot reads stay body-free; a body is hydrated on demand only when a row is opened (see `FlowStore.hydrated` / SQLite BLOB columns). Never load megabyte bodies to render a list.
  - **Aggregate incrementally, coalesce updates.** Sidebar counts (hosts / apps / devices / errors) are maintained as flows arrive (`AppFeature.State.recordFlow` → `contribute`/`retract`), never recomputed by scanning the list on render, and the live flow stream is batched into one action per ~100 ms window (`AppFeature.streamFlows`) instead of one action per emission.
  - **Cheap row bodies.** No per-row allocation of expensive objects (date formatters, regexes, `JSONDecoder`, `URLComponents`) — hoist to a shared static or a direct scan. `Flow.host` goes through `URLHost` (an authority scan that defers to `URLComponents` only for percent-escaped / punycode / malformed URLs), and a host-filtered list compares via `URLHost.hostMatches` so it never materializes a host per row. Hand genuinely large text to AppKit (`NSTextView`), not a SwiftUI `Text`.
  - When adding any new list/table/feed, state in the PR how it stays bounded and lazy.

## Release & Auto-Update (Sparkle)

Loom self-updates via Sparkle; a `v*` tag drives `.github/workflows/release.yml` all the way to a
GitHub release with `Loom.dmg` + `appcast.xml`. The full flow and the EdDSA key handling live in
**`.claude/skills/release/SKILL.md`** (lazy-loaded). See also the Sparkle entry in Known Issues.

## Known Issues

- **Auto-update (Sparkle) is armed end-to-end; only Developer ID signing is still missing.** `UpdaterClient`/`UpdaterCoordinator` + the panel footer "Update" button work in-app: a silent probe runs at most once a day (self-gated on `com.loom.lastUpdateCheck` in UserDefaults; `SUEnableAutomaticChecks` is deliberately off so the probe stays UI-less), and a user-initiated tap shows Sparkle's install UI. `SUPublicEDKey` in `Project.swift` is a real EdDSA public key (the matching private key is in this machine's login Keychain). The `SPARKLE_EDDSA_KEY` repo secret **is set**, so the `Release` workflow builds → DMGs → signs + generates `appcast.xml` → publishes both to the GitHub release (verified: `v0.0.4` carries an `appcast.xml` asset). Remaining gap: full-strength updates want a Developer ID signed + notarized app — the CI archive is ad-hoc (`CODE_SIGN_IDENTITY="-"`). Sparkle's transitive framework module must also be listed as an explicit `.external(name: "Sparkle")` dep on any test target that `@testable import`s AppFeature (see `AppFeatureTests`).
- **Tuist ≥ 4.202.5 is required.** TCA 1.26 pulls swift-navigation 2.10, which uses SwiftPM *package traits* (`condition: .when(traits:)`). Tuist 4.176's graph loader ignores traits and drops the `CasePathsMacrosSupport` macro edge → `Unable to find module dependency`. 4.202.5's loader handles it. Pinned in `mise.toml`.
- **NIO modules are Swift 5.** Do not flip `ProxyCore`/`MCPServer` to Swift 6 without reworking the channel handlers off `@unchecked Sendable`. `SystemProxyClient` is also Swift 5 (XPC + continuations).
- **HTTPS leaf certs must use ≤20-octet serials.** `Certificate.SerialNumber()` can yield 21 octets (RFC 5280 violation) which Secure Transport rejects with `-1015 "cannot decode raw data"` — silently breaking interception for ~half of hosts while browsers (lenient BoringSSL) still work. `CertificateAuthority.makeSerialNumber()` clears the top bit; don't revert to the default initializer.
- **The forwarder strips Content-Encoding/Content-Length.** `NIOStreamingForwarder` runs a `NIOHTTPResponseDecompressor`, so the bytes reaching the client are already decompressed; it drops those two headers on `.head` (`HTTPUtil.sanitizeDecodedResponseHeaders`) — otherwise the client re-decodes plaintext and fails with -1015.
- **SSL scope persists in UserDefaults** (`com.loom.sslScope`), so HTTPS interception survives relaunch. Without it every launch reset to disabled → all HTTPS blind-tunneled → nothing captured. The test-seam engine passes `InterceptionConfig(defaults: nil)` to stay hermetic.
- **Root CA is stored in a file, not the Keychain.** `FileCAStore` keeps the CA (cert + key) in a 0600 `~/Library/Application Support/com.loom/ca-store.pem` — same as Charles/mitmproxy. This is deliberate: a Keychain item's ACL is bound to the app's code signature, so every ad-hoc rebuild during development re-prompted for the login password on the CA read. A file has no ACL → no prompt. `ProxyEngine.migratedCAStore()` migrates a legacy Keychain CA into the file once (preserving an already-trusted CA); `KeychainCAStore` remains for reference only.
- **HTTPS interception works (M2); one-click *user-domain* CA trust is wired and shipping.** With SSL on and a host in scope, Loom MITM-decrypts and captures HTTPS. Apple domains legitimately fail (cert pinning) — expected, not a bug. A client only trusts the leaf if Loom's root CA is trusted. Three ways, in order of what's actually available:
  - **One-click (user-domain) — works today, no helper, no Developer ID.** The panel's **"Install & Trust"** button (`SetupFeature.installAndTrustCATapped` → `CertificateTrust.installUserTrust`) adds the CA to the login keychain and sets user-domain trust via Authorization Services — one login-password prompt. Safari and apps using the system trust evaluation then accept Loom's leaf. This covers the common single-user case; it's the default path a user should take.
  - **Manual (system-domain).** The panel also shows a copyable `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain <path>` (get the path from `export_ca_certificate`) for machine-wide trust.
  - **Privileged helper (system-domain, unverified).** `PrivilegedHelperClient` + `LoomHelper` would install system-wide trust without the sudo step — a hardened but **unverified scaffold** (caller + Apple-binary validation, per-service proxy backup/restore, crash watchdog, idle-exit). Its `register`/`installCA` XPC path is wired in the client and its pure logic is unit-tested, but **nothing in the app invokes it yet**, and it needs a Developer ID–signed/notarized app with the daemon embedded at `Contents/Library/LaunchDaemons/com.loom.helper.plist` + admin approval — `SMAppService` rejects the ad-hoc CI signing, so it can't run in CI. User-domain trust above already unblocks interception, so this is an optional enhancement, not a blocker.
- **CONNECT surgery is order-sensitive.** In `ProxyHandler.interceptTLS` the swap runs on `.end` (after the decoder emits the CONNECT parts); handlers must conform to `RemovableChannelHandler`, the HTTP encoder is removed before TLS writes, and TLS is inserted at the pipeline head. Changing this order reintroduces `WRONG_VERSION`/decode crashes.
- **System-proxy config works without the helper (admin users, silent).** `SystemProxyApplier` runs `networksetup` directly — admin users need no password; non-admin falls back to one osascript admin prompt. State is verified via `SCDynamicStoreCopyProxies`, synced into the UI at boot, and auto-disabled on quit (`AppDelegate.applicationShouldTerminate`) — the quit path is guarded on Loom still holding the setting, so it can't clear someone else's. A crash skips the quit cleanup; the boot sync surfaces the stale override on next launch. The XPC helper remains the future option for non-admin, crash-safe installs.
- **Loom is not the only app that sets the system proxy, and the state is watched live.** Charles / Proxyman / whistle set the same setting and only one wins. `SystemProxyMonitor` follows `SCDynamicStore`'s proxy key (no polling) and `SetupFeature.task` keeps the panel honest — before this, state was read only at boot / after Loom's own write / on quit, so another app taking over left the switch claiming "on" until the panel was reopened. The answer is three-valued (`SystemProxySnapshot.routing(loomPort:)` → `.loom` / `.off` / `.other(host:port:)`), **one definition** shared by the panel row, the quit decision and `get_proxy_status` (`"on"`/`"off"`/`"other"` + `systemProxyPointsAt`). `.loom` requires *both* HTTP and HTTPS: half-routed means every `https://` bypasses Loom, which is the empty-capture case this exists to explain. Snapshots are ignored while `systemProxyBusy` — the enable script writes one network service at a time, so mid-apply readings are genuinely half-applied — and `.systemProxyResult` re-reads once to settle.
- **Loom deliberately does not back up and restore the previous proxy owner.** Owner decision: restoring is only correct if that app is still running, and Loom cannot know — re-enabling a proxy pointed at an exited Charles would break every request on the machine, which is worse than leaving the setting off. So enabling Loom overwrites, disabling turns the proxy *off* (not back to Charles), and the surfacing above is the mitigation: the panel and the agent both name who holds it, and the human switches back themselves. `ProxyBackup` / `ProxyServiceState` in HelperProtocol exist for the unverified XPC helper's own crash watchdog, **not** for this path — don't wire them in thinking it's a missing feature.
- **Enabling the system proxy also blocks QUIC (`QUICBlocker`).** Browsers default to HTTP/3 over QUIC (UDP 443), which a TCP HTTP proxy can't intercept — so without this, browser page loads bypass Loom entirely (only TCP h1/h2 app traffic is captured). The system-proxy enable script appends a pf rule dropping outbound UDP 443, forcing browsers to TCP fallback; disable/quit restores it. Safety: it copies the user's `/etc/pf.conf` and appends a `com.loom.quic` anchor (never overwrites), records prior pf-enabled state in a marker file, and restore reloads the pristine ruleset. pf needs root, so this rides the same osascript admin call as the proxy — **the live pfctl path is unit-tested + `pfctl -nf` syntax-validated but needs one real toggle to verify end-to-end** (like the other privileged paths). pf is macOS-specific: a named anchor is only evaluated because we append `anchor "com.loom.quic"` to the loaded main ruleset.
- **A custom SF Symbol can compile clean and still be `nil` at runtime.** `actool` succeeds, `Assets.car` is complete, the app builds, `Image(_:)` has no compile-time check — and the menu-bar icon is silently gone, because CoreUI refused to decode the symbol. Cause: it subdivides arcs into Béziers by radius, so variants drawn at different stroke weights get different segment counts and the weight interpolation has no point correspondence. `Tools/symbol-template/build.py` flattens every arc to a fixed chord count to avoid it, and **`check.py` is the pass condition** — it compiles the catalog and asks a real bundle for each symbol back. See DESIGN.md § Brand mark.
- **An h2 upload larger than one flow-control window can deadlock — upstream's bug, [#99](https://github.com/KQAR/Loom/issues/99), unfixed.** Roughly 1 % of the time an HTTP/2 request body over 65535 bytes stalls: the server consumes exactly one window, no further `WINDOW_UPDATE` is emitted, the client blocks on its exhausted outbound window, and every event-loop thread goes idle. **Not Loom's usage** — `Tools/h2-stall-repro/` reproduces it with SwiftNIO alone (its `plain` mode has no bridge, no read pump and no `autoRead` change and still stalls), and the pattern Loom does use is the one NIOHTTP2's own tests use. Reproduced on nio-http2 1.45.0 (latest); no upstream issue exists and we haven't filed one. Living with it: `HTTP2InterceptionTests`'s h2 upload test is instrumented to fail at 25 s with the stalled stage plus client-flushed / upstream-consumed byte counters (a stall reads `consumed = 65535`), so a red run is identifiable at a glance — **if the counters say anything else, it's a new bug, not this flake**. `.github/workflows/h2-stall-hunt.yml` (dispatch-only) reproduces it on CI in ~6 minutes.
