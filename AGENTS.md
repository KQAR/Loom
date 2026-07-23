<!-- CLAUDE.md is a symlink to this file. Always update AGENTS.md, not CLAUDE.md. -->
<!-- Rule: every edit to this file must make it MORE CONCISE or MORE USEFUL. Never add fluff. -->

# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Loom is a personal macOS 14+ app: an **AI-operable debugging proxy** that lives in the status bar. It captures HTTP/HTTPS traffic like Charles/Proxyman, but its primary operator is an AI agent talking **MCP** — and, this is the differentiator, the MCP surface exposes **write actions** (replay, rules, breakpoints), not just read queries. The agent closes the debug loop (capture → modify → replay → diff) with no GUI; the human supervises from the menu bar and gates risky writes.

[`ROADMAP.md`](ROADMAP.md) is the single source of truth for positioning and iteration order. Read it before making scope or prioritization decisions.

**Stack**: SwiftUI + TCA, Tuist, Swift 6 (NIO modules Swift 5), SwiftNIO, SPM, macOS 14+.

## Design System

Three docs govern the product; each wins over code in its domain:

- [`ROADMAP.md`](ROADMAP.md) — positioning and iteration order
- [`DESIGN.md`](DESIGN.md) — visual system for the **status-bar panel** (the whole human surface) + the optional Detail viewer, derived from Apple's HIG, **not** from existing code
- [`INTERACTION.md`](INTERACTION.md) — interaction architecture: the AI-operates / human-supervises inversion, the status-bar panel as the one surface, write-action guardrails

**UI is status-bar-first (DESIGN/INTERACTION v2).** The human surface is a single menu-bar panel (faults → approvals → live feed → control footer); there is no main window. The M1 code still has the old control-only popover + two-column Inspector window — treat that as legacy to rebuild toward the specs, not a pattern to extend.

When a current view conflicts with these specs, the view is wrong: refactor toward the spec, never propagate legacy styling. Read DESIGN.md and INTERACTION.md before writing or reviewing any view code.

## Legal boundary (read once)

Loom is a clean-room implementation. Studying open-source proxies to learn *what* to build and *what interfaces* to expose is fine, but **never copy third-party source into this repo, and never write code by transcribing someone else's** — especially copyleft (AGPL/GPL) projects. Learn MITM/NIO specifics from Apple's swift-nio examples (Apache-2.0) and mitmproxy docs. Ideas and interface shapes are fair game; literal code is not.

## Build Commands

```bash
tuist install                 # Resolve SPM dependencies
tuist generate                # Generate Loom.xcworkspace
tuist build Loom              # Build the app
tuist clean                   # Clean
tuist edit                    # Edit Tuist manifests in Xcode

# Direct xcodebuild (CI / scripted):
xcodebuild -workspace Loom.xcworkspace -scheme Loom -configuration Debug -destination 'platform=macOS' build
xcodebuild -workspace Loom.xcworkspace -scheme loom-mcp -destination 'platform=macOS' build

# Consume the engine as a plain SPM library (no Tuist / Xcode needed):
swift build                   # builds LoomSharedModels + LoomProxyCore from the root Package.swift
```

Tuist is pinned to **4.202.5** in `mise.toml` — do not downgrade (see Known Issues).

## Scope

**In scope now (M1 + M2 interception, done)**: HTTP capture proxy, HTTPS MITM interception (on-demand P-256 CA + per-host leaf certs, TLS termination, SSL-proxying scope), in-app MCP server + `loom-mcp` bridge, read tools + write tools (`replay_flow`, `set_ssl_scope`, `export_ca_certificate`), menu-bar shell + Inspector window.
**In scope now also (M3, done)**: traffic rules — structured `TrafficRule` model (no text DSL; whistle-inspired semantics only) with optional **groups** (batch enable/disable, scenario switching), applied for all paths in one choke point (`RuleApplyingForwarder` decorating `UpstreamForwarding`), persisted in UserDefaults (`com.loom.rules`), exposed as 7 MCP tools + UI (sidebar Rules panel, row context-menu rule templates, rule-hit indicators, `appliedRules` audit on flows). Plus **`diff_flows`** (structured request/response diff, closing the capture→modify→replay→diff loop) and **breakpoints** — a `Breakpoint` (reusing `RuleMatch`) holds matching traffic mid-flight via `BreakpointForwarder` (outermost `UpstreamForwarding` decorator) + a lock-based `BreakpointStore` that parks the exchange on a continuation; poll model (`list_pending`) since MCP has no server push, released with `resume` (edit or abort). Breakpoints are **not persisted** (a held exchange holds a live connection). **Owner decision: no approval mode** — all MCP write tools act directly; INTERACTION.md's approval-card gating is not implemented for rules/breakpoints by design.
**Next (ordered — see [`ROADMAP.md`](ROADMAP.md))**: finish M2 (privileged helper for system-trust install + system-proxy — currently an unverified scaffold), M4 protocol breadth (HTTP/2, WebSocket, GraphQL) + persistence.
**Deferred**: Windows/Linux, iOS device capture, team sessions, in-app LLM assistant.

## Core Concepts

### Domain Model (`SharedModels`)

- **Flow**: one captured or replayed request/response exchange. Carries `CapturedRequest`, optional `CapturedResponse`, timing, `error`, `replayedFrom` (set when produced by a replay), `sourceApp` (local process, libproc — loopback only) and `sourceDevice` (originating device: this Mac or a LAN device, keyed on remote IP, typed from User-Agent via `UserAgentParser`).
- **HeaderPair**: headers are an *ordered list*, not a dictionary — order and duplicates are preserved as seen on the wire.
- **ReplayOverrides**: how a flow is mutated before re-send (method / url / set+remove headers / body).
- **ProxyControlling** = `FlowProviding` (read) + `FlowReplaying` (write): the protocol the engine implements and both the TCA client and MCP server consume.

### Runtime Flow

```
Client (curl -x / system proxy)
  └─▶ ProxyCore :9090 ──capture──▶ FlowStore (ring buffer + AsyncStream)
                                        │
                 ┌──────────────────────┴───────────────────────┐
          ProxyClient (TCA)                               MCPServer :<port>/mcp
          drives Inspector UI                             ◀── loom-mcp bridge ◀── AI client
                 └──────── same ProxyEngine.shared, one write path ────────┘
```

Both the UI and the AI act through the **same** `ProxyEngine.shared` — "AI modifies a request" and "human clicks Replay" run identical code. Never fork a second write path.

### The AI link

Two ways in, both hitting the **same** in-process MCP server (all tools + state live in the app, sharing memory with the capture store):

- **HTTP direct (Claude Code / Cursor plugin)** — the app serves MCP over HTTP on a **fixed loopback port `127.0.0.1:9092`** (`MCPServer.defaultPort`). The `loom` plugin's root `.mcp.json` points a `type: http` server at `http://127.0.0.1:9092/mcp`; Claude/Cursor just connect — they do **not** launch or build anything, so a random-port bridge is unnecessary. Loopback requests need **no token** (`authorized()` allows a missing `Authorization` header on the loopback-only endpoint); a token, when sent, must still match. The app owning the server means: if the tools are unreachable, the app isn't running — the skill tells the agent to install/launch Loom rather than fabricate data.
- **stdio bridge (Claude Desktop / other stdio-only clients)** — `loom-mcp` is a tiny **stdio↔HTTP bridge** with no business logic. The client launches it; it reads `~/Library/Application Support/com.loom/mcp-handshake.json` (`{token, port}`, mode `0600`) and forwards each JSON-RPC line to the app's HTTP endpoint with `Authorization: Bearer <token>`. Still works because the app writes the handshake with whatever port it bound (now the fixed `9092`).

**Plugin packaging.** The repo root doubles as a Claude Code / Cursor plugin (modelled on KQAR/Reticle): `.claude-plugin/` + `.cursor-plugin/` (`plugin.json` + `marketplace.json`, `source: "./"`), a shared root `.mcp.json` (the HTTP server above), and `skills/loom/SKILL.md` documenting the tools + the debug loop. The MCP endpoint stays **loopback-only on its own port** — deliberately NOT the proxy's `9090`, which binds `0.0.0.0` when LAN device connection is on and would otherwise expose the write-capable, token-optional control plane to the whole Wi-Fi.

### MCP Tools

| Tool | Kind | Purpose |
|------|------|---------|
| `get_version` | read | app + protocol version |
| `get_proxy_status` | read | running state, port, captured count |
| `list_devices` | read | devices that sent traffic through the proxy (this Mac + LAN devices), typed from User-Agent, with per-device flow counts + last-seen |
| `get_recent_flows` | read | newest-first flow summaries |
| `get_flow_detail` | read | full headers + body for one flow id |
| `diff_flows` | read | structured diff of two flows (method/url, request+response headers add/remove/change, status, line-level body diff); `base` alone diffs a replay against its `replayedFrom` original |
| `replay_flow` | **write** | re-send a flow with overrides → new flow, linked via `replayedFrom` |
| `arm_breakpoint` | **write** | hold matching traffic mid-flight (request and/or response phase) for inspection/editing; match reuses `RuleMatch` |
| `disarm_breakpoint` | **write** | remove an armed breakpoint by id |
| `list_pending` | read | armed breakpoints + exchanges currently held awaiting a resume decision (poll model — MCP has no server push) |
| `resume` | **write** | release a held exchange by pending id: apply edits (method/url/status/headers/body) and continue, or `abort` with a 502 |
| `get_certificate_status` | read | MITM root-CA state: generated? trusted? fingerprint, expiry, exported path |
| `get_ssl_scope` | read | current interception scope (enabled + include/exclude host globs) |
| `export_ca_certificate` | **write** | write the root CA (PEM) to disk for trusting; returns the path |
| `set_ssl_scope` | **write** | enable/disable HTTPS interception and set include/exclude host globs |
| `list_rules` | read | master switch + all traffic rules (long bodies truncated) |
| `get_rule` | read | one rule by id, full bodies |
| `create_rule` | **write** | structured traffic rule: URL glob/regex + methods → mock / map remote (+exclude/keep-host) / map local / rewrite req+res / find-replace substitutions (request_substitutions/response_substitutions) / block / delay; optional `group` label |
| `update_rule` | **write** | replace fields of a rule by id (per-rule enable/disable, regroup with `group`, `""` ungroups) |
| `delete_rule` | **write** | remove a rule by id |
| `set_rules_enabled` | **write** | master switch for the rule engine |
| `set_group_enabled` | **write** | enable/disable every rule in a group (scenario switching) |
| `export_har` | **write** | export captured flows to a HAR 1.2 file (host filter + limit); returns the path |

WebSocket flows (ws:// and wss:// via MITM) are captured as a single flow whose frames appear in `get_flow_detail` under `webSocket.messages` (direction/kind/text-or-bytes) and are flagged in `get_recent_flows`. GraphQL POSTs are recognized (`GraphQLParser`); `get_flow_detail` adds a `graphQL` block (kind/operationName/query/variables) and the Inspector shows a GraphQL tab. HTTP/2 is intercepted when the client negotiates ALPN `h2`: the MITM leaf advertises `h2`+`http/1.1`, and each h2 stream is demuxed through the h2↔h1 codec into the same `TLSInterceptHandler` capture path (falls back to http/1.1 otherwise). Completed flows persist to `~/Library/Application Support/com.loom/flows.sqlite` and reload on launch.

Write tools are the reason Loom exists. When adding one, it must be scoped and — if destructive — gated per [`INTERACTION.md`](INTERACTION.md).

### Key Modules

| Module | Layer | Responsibility |
|--------|-------|----------------|
| **SharedModels** | base | `Flow`, `ReplayOverrides`, `ProxyControlling`, `SSLScope`, `CertificateStatus`, helper XPC protocol + `HelperIdentity`, `ProxyBackup`/`SystemProxyParsing` — no deps |
| **ProxyCore** | engine | SwiftNIO proxy, `ProxyEngine` actor, `FlowStore`, CONNECT tunnel, **MITM** (`CertificateAuthority`, `TLSInterceptHandler`, `CAStore`, `InterceptionConfig`), `UpstreamForwarding` |
| **MCPServer** | engine | loopback JSON-RPC HTTP server (fixed port 9092, loopback token-optional), tool registry, handshake writer |
| **ProxyClient** | client | `@DependencyClient` wrapping `ProxyEngine.shared` for TCA |
| **PrivilegedHelperClient** | client | app-side TCA surface over the helper: SMAppService register/approve + XPC (system proxy, CA trust) — **unverified scaffold** |
| **UpdaterClient** | client | `@DependencyClient` over **Sparkle** (`UpdaterCoordinator` owns `SPUStandardUpdaterController`); silent once-a-day probe + user-initiated check, feeds the panel's footer "Update" button — Swift 5 mode |
| **AppFeature** | feature | TCA reducer + status-bar panel (live feed) + optional Detail viewer |
| **Loom** | app | MenuBarExtra entry (panel); boots proxy + MCP server |
| **loom-mcp** | tool | stdio↔HTTP bridge binary |
| **LoomHelper** | tool | root daemon: per-service proxy backup/override/restore, CA trust install/verify, caller + Apple-binary validation, crash watchdog, idle-exit — **unverified scaffold** |

## Architecture

### TCA (The Composable Architecture)

- **Reducer**: `@Reducer` macro with `State`, `Action`, `body`.
- **State**: `@ObservableState` struct, `Equatable`; flows held in `IdentifiedArrayOf<Flow>`.
- **View**: SwiftUI with `StoreOf<Feature>`, `@Bindable` store; state→action bindings via `.sending`.
- **Dependencies**: `@DependencyClient` + `DependencyValues` extension. The engine is reached only through `ProxyClient` — reducers never touch NIO.

### Layering (dependency direction is one-way)

```
App → AppFeature → ProxyClient → ProxyCore → SharedModels
                    MCPServer  ─────────────▶ SharedModels
```

Features never depend on each other (M1 keeps a single `AppFeature`; split later). Engine modules never depend on TCA.

### Library reuse (SPM)

The capture engine is reusable by **any** Swift host (a CLI, another macOS app, a test harness) — not just this app. A root `Package.swift` exposes the two lowest layers as SPM library products; everything above them (App / Features / Clients / Bridge / MCPServer / PrivilegedHelper) stays out of the package on purpose.

| Product | Target | For a consumer that wants… |
|---------|--------|----------------------------|
| `LoomSharedModels` | `SharedModels` | just the value types (`Flow`, `CapturedRequest/Response`, `HeaderPair`, rules, HAR) — Foundation-only, no NIO |
| `LoomProxyCore` | `ProxyCore` | the full engine: NIO proxy, HTTPS MITM, on-demand CA, traffic rules, replay (pulls in `LoomSharedModels`) |

- **Coexists with Tuist**: `tuist generate` still builds the app from `Project.swift`; `swift build` and external SPM consumers use the root `Package.swift`. The root manifest re-declares `ProxyCore` in **Swift 5 language mode** (same reason as `Project.swift`) and pins the NIO/certificates deps to ranges that include what a typical NIO consumer already resolves, so both graphs share one solution. Consuming it adds `swift-nio-http2` + `swift-nio-extras` to the consumer's tree.
- **Embed the engine**: construct `ProxyEngine(persistFlows: false)` when the host keeps captured flows in its own store — flows then live only in the in-memory ring and the live `flowStream()`, with no second copy in Loom's SQLite (`ProxyEngine()` keeps the durable store). Then `try await engine.start(port:)`, consume `for await flow in await engine.flowStream()`, and drive HTTPS/rules via `caCertificateDER()` / `exportCACertificate()` / `addRule(_:)`. The host installs the CA into whatever trust store its target needs; Loom's own macOS-keychain trust path is optional and not required to embed.

### Concurrency

- **App / Features / Clients**: Swift 6 language mode, strict concurrency.
- **ProxyCore + MCPServer**: **Swift 5 language mode** (`SWIFT_VERSION=5.0` in `Project.swift`). SwiftNIO's channel model fights Swift 6 Sendable; handlers are `@unchecked Sendable`. Keep NIO code in these two modules; do not leak channel types across the client boundary.
- `ProxyEngine` and `FlowStore` are **actors**; the shared engine is `ProxyEngine.shared`.
- Replay and proxy forwarding use a hand-rolled SwiftNIO upstream client (`NIOStreamingForwarder`, M4) — Loom owns every request header, so a map-remote rule's `keepHostHeader` is honored (default drops Host so it follows the mapped origin). Responses **stream** chunk-by-chunk: `forwardStream` yields head/body/end events, `StreamRelay` relays them to the client (chunked framing, keep-alive preserved) while capturing a body copy capped at `StreamRelay.captureCap` (SSE/long-poll won't grow the store unbounded). A rule that rewrites/mocks/blocks the response falls back to buffering (needs the whole body); response-untouched exchanges stream. gzip/deflate is decompressed via `NIOHTTPResponseDecompressor`. Replay still buffers via `forward` (which now drains `forwardStream`). `URLSessionForwarder` remains only as reference. **Request bodies also stream** (M4): `forwardStream` takes a `RequestBody` (`.bytes` for replay/buffered, or a back-pressured `.stream`); the request handlers bridge inbound body chunks through `RequestBodyBridge` (a `NIOThrowingAsyncSequenceProducer` with a high/low-watermark strategy whose `produceMore()` drives `channel.read()`, so a fast uploader can't outrun a slow upstream — in-flight bytes stay bounded to the watermark, not the body size; `autoRead` is paused during a body stream). The `NIOStreamingForwarder` writes chunks awaiting each flush (chaining upstream back-pressure), framed by the client's Content-Length or re-framed chunked. A capped `RequestBodyCapture` tees the body for the flow (`StreamRelay` backfills it — the request finishes before the response head). A rule that mutates the request body / short-circuits (mock/block/mapLocal) or a breakpoint that matches forces buffering (`RequestBody.collect()`); pure passthrough streams. Not yet streamed: WebSocket, HTTP/2 request bodies.

### Conventions

- **Side effects**: always through TCA `Effect` — no async work in views.
- **One write path**: UI and MCP both go through `ProxyEngine.shared`. Adding a write must extend `ProxyControlling`, not bypass it.
- **Bundle prefix**: `com.loom` (personal project — no employer branding anywhere).
- **UI**: follow [`DESIGN.md`](DESIGN.md) — semantic system colors, text styles, capsule controls. Never inline hex or fixed font sizes.

### Project Structure

```
Package.swift                     # Root SPM manifest: LoomSharedModels + LoomProxyCore library products (see "Library reuse")
Project.swift                     # Tuist project manifest (all targets)
Tuist.swift                       # Tuist config
Tuist/Package.swift               # SPM dependencies (TCA, swift-nio, swift-nio-ssl, swift-certificates)
Tuist/ProjectDescriptionHelpers/  # Module() target factory
App/Sources/                      # LoomApp (MenuBarExtra + boot)
Features/AppFeature/Sources/      # reducer + MenuBarView + InspectorView
Clients/ProxyClient/Sources/      # TCA dependency over the engine
Clients/PrivilegedHelperClient/Sources/ # app-side surface over the helper (scaffold)
Clients/UpdaterClient/Sources/    # TCA @DependencyClient over Sparkle (auto-update)
Engine/ProxyCore/Sources/         # NIO proxy, ProxyEngine, FlowStore, MITM (CA, TLS intercept)
Engine/ProxyCore/Tests/           # unit + HTTPS-interception integration tests
Engine/MCPServer/Sources/         # MCP server, tools, handshake
Engine/PrivilegedHelper/Sources/  # LoomHelper root daemon (scaffold); com.loom.helper.plist alongside
SharedModels/Sources/             # Flow, ReplayOverrides, ProxyControlling, SSLScope, CertificateStatus
Bridge/Sources/                   # loom-mcp stdio↔HTTP bridge
.mcp.json                         # plugin MCP config: http → 127.0.0.1:9092/mcp (Claude Code + Cursor)
.claude-plugin/                   # Claude Code plugin manifest + marketplace
.cursor-plugin/                   # Cursor plugin manifest + marketplace
skills/loom/SKILL.md              # skill: how to drive Loom over MCP (tools + debug loop)
```

## Release & Auto-Update (Sparkle)

Loom self-updates via [Sparkle](https://sparkle-project.org) (same engine as the reference `looper`). The human sees a footer **"Update"** button in the status-bar panel; the app probes silently once a day and shows Sparkle's install UI on tap.

**In-app pieces**: `UpdaterClient` (TCA dependency) → `UpdaterCoordinator` (owns `SPUStandardUpdaterController`). `AppFeature` subscribes to availability and drives the panel button. Config lives in `Project.swift` infoPlist: `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks: false` (we drive cadence ourselves).

**Keys**: the EdDSA key pair is managed by Sparkle's `generate_keys` (private key in the login Keychain, public key committed as `SUPublicEDKey`). Regenerate only when rotating:
```
Tuist/.build/artifacts/sparkle/Sparkle/bin/generate_keys        # show/create the key
Tuist/.build/artifacts/sparkle/Sparkle/bin/generate_keys -x key # export private key → CI secret
```

**Release flow** — fully automated by `.github/workflows/release.yml` (triggers on a `v*` tag):
```bash
git tag v0.1.0 && git push origin v0.1.0
```
The workflow: `tuist install/generate` → `xcodebuild archive` (ad-hoc signed) → `scripts/create-dmg.sh` → `sign_update` + `generate_appcast` → `gh release create` with `Loom.dmg` + `appcast.xml`.

**One-time setup**: add repo secret **`SPARKLE_EDDSA_KEY`** (the exported private key). Without it the workflow still publishes the DMG but omits the appcast, so auto-update stays dormant. For Gatekeeper-clean installs, additionally sign + notarize with a Developer ID (the CI archive is currently ad-hoc, `CODE_SIGN_IDENTITY="-"`).

**Sparkle tools** (fetched by `tuist install` into `Tuist/.build/artifacts/sparkle/Sparkle/bin`): `generate_keys`, `sign_update`, `generate_appcast`.

## Known Issues

- **Auto-update (Sparkle): in-app + release plumbing done; the CI secret is the one manual step.** `UpdaterClient`/`UpdaterCoordinator` + the panel footer "Update" button work in-app: a silent probe runs at most once a day (self-gated on `com.loom.lastUpdateCheck` in UserDefaults; `SUEnableAutomaticChecks` is deliberately off so the probe stays UI-less), and a user-initiated tap shows Sparkle's install UI. `SUPublicEDKey` in `Project.swift` is a real EdDSA public key (the matching private key is in this machine's login Keychain). The `Release` workflow builds → DMGs → signs + generates `appcast.xml` → publishes to the GitHub release. **To arm auto-update, set the `SPARKLE_EDDSA_KEY` repo secret** (export with `generate_keys -x`); without it the workflow still ships the DMG but skips the appcast, so nothing self-updates. Full-strength updates additionally want a Developer ID signed + notarized app (the CI archive is ad-hoc `CODE_SIGN_IDENTITY="-"`). Sparkle's transitive framework module must also be listed as an explicit `.external(name: "Sparkle")` dep on any test target that `@testable import`s AppFeature (see `AppFeatureTests`).
- **Tuist ≥ 4.202.5 is required.** TCA 1.26 pulls swift-navigation 2.10, which uses SwiftPM *package traits* (`condition: .when(traits:)`). Tuist 4.176's graph loader ignores traits and drops the `CasePathsMacrosSupport` macro edge → `Unable to find module dependency`. 4.202.5's loader handles it. Pinned in `mise.toml`.
- **NIO modules are Swift 5.** Do not flip `ProxyCore`/`MCPServer` to Swift 6 without reworking the channel handlers off `@unchecked Sendable`. `SystemProxyClient` is also Swift 5 (XPC + continuations).
- **HTTPS leaf certs must use ≤20-octet serials.** `Certificate.SerialNumber()` can yield 21 octets (RFC 5280 violation) which Secure Transport rejects with `-1015 "cannot decode raw data"` — silently breaking interception for ~half of hosts while browsers (lenient BoringSSL) still work. `CertificateAuthority.makeSerialNumber()` clears the top bit; don't revert to the default initializer.
- **The forwarder strips Content-Encoding/Content-Length.** URLSession auto-decompresses upstream bodies, so `URLSessionForwarder` drops those headers (`HTTPUtil.sanitizeDecodedResponseHeaders`) — otherwise the client re-decodes plaintext and fails with -1015.
- **SSL scope persists in UserDefaults** (`com.loom.sslScope`), so HTTPS interception survives relaunch. Without it every launch reset to disabled → all HTTPS blind-tunneled → nothing captured. The test-seam engine passes `InterceptionConfig(defaults: nil)` to stay hermetic.
- **Root CA is stored in a file, not the Keychain.** `FileCAStore` keeps the CA (cert + key) in a 0600 `~/Library/Application Support/com.loom/ca-store.pem` — same as Charles/mitmproxy. This is deliberate: a Keychain item's ACL is bound to the app's code signature, so every ad-hoc rebuild during development re-prompted for the login password on the CA read. A file has no ACL → no prompt. `ProxyEngine.migratedCAStore()` migrates a legacy Keychain CA into the file once (preserving an already-trusted CA); `KeychainCAStore` remains for reference only.
- **HTTPS interception works (M2), but the CA must be trusted manually.** With SSL on and a host in scope, Loom MITM-decrypts and captures HTTPS. Apple domains legitimately fail (cert pinning) — expected, not a bug. A client only trusts the leaf if Loom's root CA is trusted: run `export_ca_certificate`, then `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain <path>`. The one-click privileged install (`PrivilegedHelperClient` + `LoomHelper`) is a hardened but **unverified scaffold** (caller + Apple-binary validation, per-service proxy backup/restore, crash watchdog, idle-exit). It compiles and its pure logic is unit-tested, but it needs a signed/notarized app with the daemon embedded at `Contents/Library/LaunchDaemons/com.loom.helper.plist` + admin approval, which can't run in CI.
- **CONNECT surgery is order-sensitive.** In `ProxyHandler.interceptTLS` the swap runs on `.end` (after the decoder emits the CONNECT parts); handlers must conform to `RemovableChannelHandler`, the HTTP encoder is removed before TLS writes, and TLS is inserted at the pipeline head. Changing this order reintroduces `WRONG_VERSION`/decode crashes.
- **System-proxy config works without the helper (admin users, silent).** `SystemProxyApplier` runs `networksetup` directly — admin users need no password; non-admin falls back to one osascript admin prompt. State is verified via `SCDynamicStoreCopyProxies`, synced into the UI at boot, and auto-disabled on quit (`AppDelegate.applicationShouldTerminate`). A crash skips the quit cleanup; the boot sync surfaces the stale override on next launch. The XPC helper remains the future option for non-admin, crash-safe installs.
- **Enabling the system proxy also blocks QUIC (`QUICBlocker`).** Browsers default to HTTP/3 over QUIC (UDP 443), which a TCP HTTP proxy can't intercept — so without this, browser page loads bypass Loom entirely (only TCP h1/h2 app traffic is captured). The system-proxy enable script appends a pf rule dropping outbound UDP 443, forcing browsers to TCP fallback; disable/quit restores it. Safety: it copies the user's `/etc/pf.conf` and appends a `com.loom.quic` anchor (never overwrites), records prior pf-enabled state in a marker file, and restore reloads the pristine ruleset. pf needs root, so this rides the same osascript admin call as the proxy — **the live pfctl path is unit-tested + `pfctl -nf` syntax-validated but needs one real toggle to verify end-to-end** (like the other privileged paths). pf is macOS-specific: a named anchor is only evaluated because we append `anchor "com.loom.quic"` to the loaded main ruleset.
