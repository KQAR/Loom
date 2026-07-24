# ProxyCore Forwarding Architecture — Exchange Event Model

Status: **implemented** (migration steps 1–3 done; step 4 deemed not needed — see
Migration). The shipped realization is a pragmatic subset of the idealized model below.
Scope: the upstream leg of a proxied exchange in `ProxyCore` — the `UpstreamForwarding`
chain (`NIOStreamingForwarder` → `RuleApplyingForwarder` → `BreakpointForwarder`),
`StreamRelay`, and how a `Flow` is built.

## Realization (what actually shipped)

The event type is the existing **`UpstreamResponseEvent`**, extended with a leading
**`metadata(appliedRules:)`** case (the `planned` event below) alongside `head` / `body`
/ `end`; `metadata` is the single carrier of applied rules and is emitted before the
network call, so it survives a failure on every path (live streaming, live buffered,
replay, and held breakpoints). The richer `ExchangeEvent` vocabulary sketched below
(`requestForwarded`, `responseBodyObserved`, `wsFrame`, distinct `completed`/`failed`)
and the explicit **data/observation plane split** were evaluated and **not built**: the
existing enum + `StreamRelay`'s already-capped body capture + the separate
`WebSocketTapHandler` already deliver the end-state properties (single failure-surviving
carrier, bounded observation) without touching the hot per-chunk path. The sections that
follow describe the idealized target; the **Migration** section records what was done.

## Why

Two coupled problems in the current chain:

1. **Metadata is lost on failure.** `appliedRules` (and any exchange-level metadata)
   rides on the `.head` response event, so it is dropped whenever the exchange fails
   *before* a response head — e.g. a map-remote rule pointing at a dead upstream. The
   failed `Flow` then shows no rule-hit (no UI wand icon, no `appliedRules` over MCP),
   on the streaming path and the buffered/replay paths alike.
2. **Two hand-synced production paths.** `forward` (buffered → `ForwardResult`) and
   `forwardStream` (→ event stream) both attach metadata independently. Drift between
   them is *how* problem (1) happens.

Root cause: exchange-level metadata is modeled as response-level data, and success vs
failure is asymmetric — success has a carrier (`.head` / `ForwardResult`), failure has
none.

## Principle

Model one proxied exchange as a single **back-pressured lifecycle event stream**.
Success and failure are both *terminal events*, and both retain whatever metadata was
emitted earlier. There is **one** production path; buffered `ForwardResult` becomes a
fold over the stream.

Split two planes:

- **Data plane** — moves wire bytes to the client under back-pressure (streaming relay,
  WebSocket splice). Performance-critical; unchanged in spirit.
- **Observation plane** — the typed `ExchangeEvent` stream the `FlowStore` folds into a
  `Flow`. Low-frequency control events + *capped* body observations only.

## `ExchangeEvent` (observation plane)

```swift
enum ExchangeEvent: Sendable {
  case planned(appliedRules: [AppliedRule])            // first, before the network; empty if no rule matched
  case requestForwarded(method: String, url: URL, headers: [HeaderPair])  // post-rewrite request actually sent
  case responseHead(statusCode: Int, httpVersion: String?, headers: [HeaderPair])
  case responseBodyObserved(Data)                      // CAPPED copy for inspection — NOT the wire bytes
  case wsFrame(direction: WSDirection, kind: WSKind, payload: Data)        // capped observation
  case completed(at: Date)
  case failed(FlowError, at: Date)                     // terminal; earlier metadata stays on the Flow
}
```

Ordering contract: `planned?` → `requestForwarded` → ( `responseHead` →
`responseBodyObserved`* )? → ( `completed` | `failed` ). `wsFrame`* interleaves after
`responseHead` on an upgraded connection. **Exactly one terminal event.**

## The one hard rule (keeps back-pressure + bounded memory)

`responseBodyObserved` / `wsFrame` payloads are **capped observation copies** (reuse
`StreamRelay.captureCap`) — never the authoritative byte path, never retained beyond the
bounded `Flow` projection. Wire bytes move on the data plane under the existing
high/low-watermark back-pressure (`RequestBodyBridge`). **The event stream must never be
treated as a replayable byte log.** (See "Replay & the body boundary".)

**This is a preserved invariant, not a new capability.** The current architecture
already caps the retained/observed body at `StreamRelay.captureCap` (5 MB) on both the
request and response sides, streaming and buffered alike, and persists only that capped
copy to SQLite. Every migration step below MUST preserve this bound and must never
regress it — `responseBodyObserved` carries the capped copy, exactly as today.

## Producers

- **`NIOStreamingForwarder`** (base): emits `requestForwarded`, `responseHead`,
  `responseBodyObserved`, then `completed` / `failed`. Never `planned` (no rule
  knowledge).
- **`RuleApplyingForwarder`**: emits `planned(appliedRules:)` **first** — known
  synchronously from the plan, *before* the network call — then forwards base events.
  Because `planned` precedes the connection attempt, `appliedRules` survives a
  connection failure: the downstream `failed` terminal is emitted after `planned`.
- **`BreakpointForwarder`** (outermost): forwards events untouched on the fast path; on
  a matched hold it emits the same event sequence around the buffered edit.

**Single production path:** `forward(...) -> ForwardResult` is implemented as
`fold(forwardStream(...))`. No second hand-synced path. `ForwardResult.appliedRules`
becomes just the projection of the `planned` event.

## Projection — `FlowStore` folds `ExchangeEvent` into a `Flow`

- `planned` → stash `appliedRules` (attached to every later upsert, **including
  `failed`**).
- `responseHead` → `.streaming` outcome.
- `responseBodyObserved` → append to the capped captured body.
- `completed` → `.completed`; `failed` → `.failed(partialResponse:)`, carrying
  `appliedRules`.

## Data plane — client byte relay is a separate consumer

`StreamRelay` writes wire bytes to the client channel with keep-alive / chunked framing
exactly as today, driven by the same back-pressured upstream stream. It is a *consumer
of the data plane*, distinct from the observation fold. (Migration step 3 decides
whether to tee one upstream stream into both consumers, or keep `StreamRelay` emitting
the observation events.)

## WebSocket

The byte-transparent `WebSocketRelay` splice stays on the data plane — no parse, no
reframe, no buffer. `WebSocketTapHandler` emits capped `wsFrame` observation events onto
the observation plane. WS is thus a frame timeline for the `Flow` without touching the
splice's throughput.

## Replay & the body boundary

Replay in Loom is **re-execution** (`replay_flow` re-sends the request), **not** log-fold
reconstruction — so lossless replay never depends on retaining bodies. The architecture:

- **fully** event-sources the **control/metadata plane** (small, cheap; persistable /
  auditable if ever wanted);
- keeps **bounded, capped** body capture for the inspector + SQLite (already exists),
  hydrated on demand.

It deliberately does **not** retain **unbounded** body bytes as a replayable append-only
log. That is a *resource policy* (bounded memory; infinite SSE / streams), **not** an
architectural inability — the cap is tunable / opt-in per host. Over-cap bodies are
truncated for inspection: the same tradeoff as Charles / Proxyman.

## Migration (incremental — each step independently shippable + testable)

1. **DONE.** Add a leading `metadata(appliedRules:)` event to `UpstreamResponseEvent`
   (the embryonic `planned`) — the sole rule carrier, so `.head` no longer carries
   `appliedRules`. `RuleApplyingForwarder` emits it first (both the streaming and the
   buffering branch), *before* the network call; `StreamRelay` records it before any
   head/error and attaches it to the failed-flow upsert. → fixes every exchange that
   flows through `forwardStream`/`StreamRelay`: **all live streaming + rule-buffered
   traffic**, including the reported map-remote-to-dead-upstream case. Covered by
   `AppliedRulesOnFailureTests`. *Not yet fixed:* the pure buffered `forward` →
   `ForwardResult` failure paths (replay via `ProxyEngine.replay`, and a
   breakpoint-matched hold whose `forward` throws) — see step 2.
2. **DONE.** `ProxyEngine.replay` now consumes `forwardStream` (folding it into the
   replayed flow) instead of the buffered `forward`, so a replay that matches a rule
   but fails to connect records its rule hits via `.metadata` — same as live traffic.
   `RuleApplyingForwarder.forward` is likewise a fold over its own `forwardStream`
   (`NIOStreamingForwarder.forward` already was), so applied rules have a single source
   (`.metadata`) and the buffered path can't drift from the stream. The top-level
   buffered `forward` now has **no external consumer** — it survives only as internal
   plumbing the decorators use to buffer a body (short-circuit / rewrite / breakpoint
   hold). Covered by `AppliedRulesOnFailureTests` (replay case).
   (The one remaining gap after this step — a held breakpoint whose upstream fails — is
   closed in step 3.)
3. **DONE — breakpoint choke point is event-native.** `BreakpointForwarder.forwardStream`
   is now the single hold implementation: it runs the request-phase hold, consumes
   `base.forwardStream` while **passing `.metadata` straight through as it arrives**
   (then buffers the response for the response-phase hold), so a held exchange that then
   fails upstream still records its rule hits. `BreakpointForwarder.forward` is a fold
   over that stream (like the others). Now **every** path — live streaming, live
   buffered, replay, and held breakpoints — carries `appliedRules` on failure via the
   one `.metadata` event. Covered by `AppliedRulesOnFailureTests`
   (`breakpoint_heldRequest_upstreamFails_stillEmitsMetadata`) and the existing
   `BreakpointTests` (hold/abort/timeout semantics preserved through the new stream path).
4. **NOT NEEDED — was mis-scoped.** The original step 4 ("split data / observation
   planes in `StreamRelay`") is not required by the end-state model. That model is: one
   event vocabulary (`.metadata`/head/body/end), one production path (`forward` = fold of
   `forwardStream` everywhere), and uniform consumption (live **and** replay fold the
   same stream) — all achieved by steps 1–3. Splitting `StreamRelay`'s single relay+build
   loop into two consumers, and rerouting the already-separate WS tap "onto an observation
   plane," is an optional implementation refactor with no functional gain that would touch
   the hottest per-chunk code. Do it only if a second cross-cutting observation need ever
   makes the abstraction pay for itself.

`ForwardResult.appliedRules` has been **removed**. It had no production reader after
steps 1–3 (the only reader was the default `forward`→stream adapter, used solely by
forward-only test stubs), so the `.metadata` event is now the **single representation** of
applied rules and `ForwardResult` is purely the buffered response (status / version /
headers / body). Tests assert applied rules by draining `forwardStream` for `.metadata`.

## Test matrix

- map-remote → dead upstream (streaming): `failed` Flow `appliedRules == [rule]`. *(the
  reported case)*
- response-rewrite rule → dead upstream (buffered): failed Flow carries `appliedRules`.
- replay through a matching rule → dead upstream: replayed failed Flow carries
  `appliedRules`.
- no rule + upstream error: `appliedRules == nil`, error message byte-identical to today
  (regression guard).
- large streaming response: memory stays bounded (observation capped, back-pressure
  intact).
- WebSocket: frames appear as observation events; splice throughput unaffected.

## Out of scope (YAGNI — do not build until ≥2 real needs exist)

Durable / replayable event store, generic event bus, plugin observers, replay-by-fold,
per-event persistence of body bytes.
```
