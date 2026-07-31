---
name: embed-engine
description: Consume Loom's capture engine as a plain SPM library from another Swift host (CLI, app, test harness) — the LoomSharedModels / LoomProxyCore products, zero-retention embedding, and the flow-emission contract. Use when wiring the engine into a non-Loom host, changing the root Package.swift, or answering "can I reuse the proxy without the app".
---

# Reusing the engine as an SPM library

The capture engine is reusable by **any** Swift host (a CLI, another macOS app, a test harness) —
not just this app. A root `Package.swift` exposes the two lowest layers as SPM library products;
everything above them (App / Features / Clients / Bridge / MCPServer / PrivilegedHelper) stays out
of the package on purpose.

| Product | Target | For a consumer that wants… |
|---------|--------|----------------------------|
| `LoomSharedModels` | `SharedModels` | just the value types (`Flow`, `CapturedRequest/Response`, `HeaderPair`, rules, HAR) — Foundation-only, no NIO |
| `LoomProxyCore` | `ProxyCore` | the full engine: NIO proxy, HTTPS MITM, on-demand CA, traffic rules, replay (pulls in `LoomSharedModels`) |

```bash
swift build   # builds LoomSharedModels + LoomProxyCore from the root Package.swift
```

## Depending on it

Pin a released tag rather than a path or a branch:

```swift
.package(url: "https://github.com/KQAR/Loom.git", from: "0.0.11"),
// then, per target:
.product(name: "LoomProxyCore", package: "Loom"),
```

The `v*` tags that drive the app's release workflow **are** the library's SemVer tags (SwiftPM
strips the leading `v`) — engine and app ship from one commit, so a second version line would only
drift. While `0.0.x`, treat every release as potentially breaking: SemVer gives no compatibility
promise below 1.0, so `exact:` is the honest pin for a consumer that wants stability.

The root **`Package.resolved` is deliberately not committed** (it's gitignored). This package is a
library: pinning transitive versions here would fight the consumer's own resolution, and the version
*ranges* in `Package.swift` are the real contract — chosen wide enough to co-resolve with what a
typical NIO consumer already has. `Tuist/Package.resolved` is committed for the opposite reason: it
pins the app's own build.

## Coexists with Tuist

`tuist generate` still builds the app from `Project.swift`; `swift build` and external SPM consumers
use the root `Package.swift`. The root manifest re-declares `ProxyCore` in **Swift 5 language mode**
(same reason as `Project.swift`) and pins the NIO/certificates deps to ranges that include what a
typical NIO consumer already resolves, so both graphs share one solution. Consuming it adds
`swift-nio-http2` + `swift-nio-extras` to the consumer's tree.

## Embedding the engine

Construct `ProxyEngine(persistFlows: false)` when the host keeps captured flows in its own store —
flows then live only in the in-memory ring and the live `flowStream()`, with no second copy in
Loom's SQLite (`ProxyEngine()` keeps the durable store). Then:

```swift
try await engine.start(port: 9090)
for await flow in await engine.flowStream() { … }
```

Drive HTTPS/rules via `caCertificateDER()` / `exportCACertificate()` / `addRule(_:)`. The host
installs the CA into whatever trust store its target needs; Loom's own macOS-keychain trust path is
optional and **not** required to embed.

## Zero-retention embedding

Pass `capacity: 0` (store-less — nothing kept between captures) and/or an `observer: FlowObserving`
sink to `ProxyEngine(persistFlows:capacity:observer:)`; the observer is pushed the same sequence as
`flowStream()`. Replay a flow the host stored itself with `replay(flow:overrides:)` so replay
doesn't depend on Loom's ring.

## The emission contract

What the stream/observer guarantee — documented on `FlowProviding.flowStream()`:

- the same id is emitted on start **and** on each state change
- `.streaming` updates arrive mid-flight
- a WebSocket flow re-emits per frame on one long-lived flow
- one h2 stream = one flow
- replays carry `replayedFrom`
- `sourceDevice` is derived from the remote IP
- late subscribers miss history
