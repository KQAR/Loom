<!-- Loaded only when working under Engine/ProxyCore/. Engine-level detail that used to sit in
     the always-loaded root AGENTS.md. Architecture rationale: FORWARDING.md alongside. -->

# ProxyCore — forwarding & streaming contract

Read [`FORWARDING.md`](FORWARDING.md) for the exchange-event model and the rationale. This file is
the working summary of what must stay true when touching the forward path.

The load-bearing properties below are pinned by `Tests/EngineInvariantTests.swift` — one write path,
body hydration, one rule choke point, breakpoints always release, replay links its flow. If a change
here is right and one of those fails, the invariant is what needs re-deciding, not the test.

## One production path

Replay and proxy forwarding use a hand-rolled SwiftNIO upstream client (`NIOStreamingForwarder`,
M4) — Loom owns every request header, so a map-remote rule's `keepHostHeader` is honored (default
drops Host so it follows the mapped origin). `forward` (buffered) is a **fold** over
`forwardStream` (`.collect()`), and replay folds `forwardStream` too. Never add a second path.

## Response streaming

- `forwardStream` yields head/body/end events; `StreamRelay` relays them to the client (chunked
  framing, keep-alive preserved) while capturing a body copy capped at `StreamRelay.captureCap`,
  so SSE/long-poll can't grow the store unbounded.
- gzip/deflate is decompressed via `NIOHTTPResponseDecompressor`.
- A rule that rewrites/mocks/blocks the response **falls back to buffering** (it needs the whole
  body); response-untouched exchanges stream.
- Applied rules ride a leading `metadata` event emitted **before** the network call, so an exchange
  that fails before any response head (e.g. map-remote to a dead upstream) still records its rule
  hits on the flow.

## Request-body streaming (M4, HTTP/1.1 + HTTP/2)

- `forwardStream` takes a `RequestBody`: `.bytes` for replay/buffered, or a back-pressured
  `.stream`. Request handlers bridge inbound chunks through `RequestBodyBridge` — a
  `NIOThrowingAsyncSequenceProducer` with a high/low-watermark strategy whose `produceMore()` drives
  `channel.read()`, so a fast uploader can't outrun a slow upstream. **In-flight bytes stay bounded
  to the watermark, not the body size**; `autoRead` is paused during a body stream.
- The stream starts **lazily on the first body chunk**, not from the head — that's what lets an h2
  DATA body with no `Content-Length` stream. On an h2 stream channel the bridge's `read()`
  replenishes the flow-control window, so h2 back-pressure works end to end.
- `NIOStreamingForwarder` writes chunks awaiting each flush (chaining upstream back-pressure),
  framed by the client's Content-Length or re-framed chunked.
- A capped `RequestBodyCapture` tees the body for the flow; `StreamRelay` backfills it, because the
  request finishes before the response head.
- A rule that mutates the request body or short-circuits (mock/block/mapLocal), or a breakpoint that
  matches, **forces buffering** (`RequestBody.collect()`). Pure passthrough streams.

## A capped capture is never silent

- `CapturedRequest`/`CapturedResponse.fullBodyBytes` records the true wire size whenever `body` is
  only a prefix (`isBodyTruncated`); `Flow.webSocketDroppedMessages` counts frames the WS cap
  dropped.
- The fact must surface everywhere: `get_recent_flows` (`captureTruncated`), `get_flow_detail`
  (`bodyCaptureTruncated` + `bodyBytesOnWire`, `webSocket.framesNotRecorded`), HAR (`bodySize` =
  wire size + `_bodyTruncated`) and the Inspector body pane.

## WebSocket

Already streamed and never buffered — a separate byte-transparent frame splice
(`WebSocketRelay`/`WebSocketTapHandler`).

## Sendable escape hatches: what each kind actually promises

Strict concurrency is on (Swift 6 language mode) and does **not** check any of these. What is left is
one kind with a removal path and one with nothing to protect — the middle kind, "lock-guarded", is
**gone**, and how it went is the useful part (§ 2).

1. **Event-loop confined** — `ProxyHandler`, `TLSInterceptHandler`, `SOCKSConnectionHandler`,
   `WebSocketTapHandler`, `StreamingResponseHandler`, `MCPHTTPHandler`. Mutable state, **no lock**;
   correctness rests entirely on every touch happening on the channel's own `EventLoop`. So: a
   `Task {}` inside one of these may not read or write `self`'s stored properties — capture the
   values it needs first, or hop back with `eventLoop.execute`. The existing `Task {}`s obey this
   (they capture an actor, e.g. `Task { await store.upsert(…) }`), and future-callback closures do
   too, because every upstream bootstrap is pinned to the client channel's loop
   (`ClientBootstrap(group: clientChannel.eventLoop)` — the `GlueHandler` splice requires it
   anyway). **Removal path**: `NIOAsyncChannel`, plus constructing handlers *inside* the pipeline
   closures so nothing non-Sendable is captured. That is the same rework as the ~24 residual
   "conformance of X to Sendable is unavailable" warnings, and it is not scheduled.
2. **Lock-guarded — no longer a hatch at all.** `RulesConfig`, `InterceptionConfig`,
   `ClientCertificateConfig`, `ReverseProxyConfig`, `RefusalLog`, `BreakpointStore`,
   `CertificateAuthority`, `RequestBodyCapture`, `ChannelBox`, `RequestBodyBridge.Delegate`,
   `ProcessResolver`, `ReservedPorts` all hold their state inside a `Synchronization.Mutex` now
   (0.0.16, when the deployment floor rose to macOS 15). Each conforms to **plain `Sendable`** —
   there is no mutable stored property left for `@unchecked` to vouch for, so the "every touch goes
   through the lock" rule is the compiler's to enforce rather than this file's to assert. **Write
   new shared state this way**, and note what it bought beyond tidiness:
   - `nonisolated(unsafe)` on a global cache is gone in four places (`RegexCache.cache`,
     `HARExport.iso8601`, `ProcessResolver.bundleInfo`, `BinaryValidator.cache`) — the value simply
     lives in the `Mutex`, which is `Sendable` whatever it holds.
   - `ProcessResolver`'s `…Locked` helper names (which encoded "the caller already holds the lock"
     in a *naming convention*) became `mutating` methods on the state struct, reachable only with
     the lock held.
   - `ReverseProxyConfig.delete` was two separate critical sections — drop the endpoint, then forget
     its bind state — so a `snapshot()` landing between them saw a deleted endpoint still carrying a
     port. One `Mutex` made it one section.

   Three rules when you touch these. **Never `await` inside `withLock`** — that is the one thing
   `NSLock` let you write and this does not, and it is the reason the API is scoped. **Resume
   continuations outside the lock**: `BreakpointStore.resolve` and `ResumeOnce.resume` take the
   continuation *under* the lock and resume it *after*, which is what makes "exactly once" true
   without ever running a waiter's continuation while the lock is held. And where the work is
   genuinely expensive — minting a leaf, parsing a trust store, a `SecStaticCode` check — keep the
   two-section shape (`check cache` / do work / `store`) rather than collapsing it for neatness.

   Two holders deliberately did **not** move: `FlowPersistence` and `AuditPersistence` are confined
   to a private serial `DispatchQueue`, because the SQLite handle isn't concurrency-safe *and*
   writes must not block the caller. A `Mutex` there would be a downgrade, not an upgrade.
3. **Immutable, hatch only for a missing upstream conformance** — `NIOStreamingForwarder` (all
   `let`; `EventLoopGroup` has no `Sendable`), `MCPTool` (a `[String: Any]` JSON schema; its
   `handler` is `@Sendable` on purpose so the hatch can't swallow a capture). Nothing to protect.

## Leaf minting on the event loop is measured and fine — don't "fix" it

`ProxyHandler.interceptTLS` and `SOCKSConnectionHandler` call `ca.serverContext(for: host)`
**synchronously on the event loop**, and on a cache miss that mints a leaf (P-256 keygen + X.509
signing) under `CertificateAuthority`'s single lock. That reads like the mistake `ProcessResolver`
documents (blocking work in the wrong execution context), so it gets raised in review. It was
measured instead: **cold 0.26 ms mean / 0.90 ms worst per host, warm 0.0003 ms** (50 distinct hosts,
in-memory CA store, arm64 debug) — 13 ms total for a page pulling in 50 new origins, spread across
their connects and an order of magnitude under one TCP round trip. Moving it off the loop would buy
that back at the cost of making the CONNECT handler swap asynchronous, and that swap's ordering is
load-bearing (see the CONNECT-surgery note in AGENTS.md § Known Issues). Not worth it. Re-measure
before reopening.
