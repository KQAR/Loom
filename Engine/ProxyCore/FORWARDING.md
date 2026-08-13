# ProxyCore Forwarding Architecture — Exchange Event Model

Status: **implemented and settled**. This doc describes the forwarding contract as it
ships, then keeps the design history (the idealized model that was evaluated, and the
migration that got here) as an appendix.
Scope: the upstream leg of a proxied exchange in `ProxyCore` — the `UpstreamForwarding`
chain (`NIOStreamingForwarder` → `RuleApplyingForwarder` → `BreakpointForwarder`),
`StreamRelay`, and how a `Flow` is built.

## The shipped contract

One proxied exchange is a single back-pressured event stream, and there is **one
production path**:

- The event type is **`UpstreamResponseEvent`**: a leading **`metadata(appliedRules:)`**
  case, then `head` / `body` / `end(trailers:)`. `metadata` is the **single carrier of
  applied rules**, emitted *before* the network call — so it survives a failure on every
  path (live streaming, live buffered, replay, and held breakpoints). A map-remote rule
  pointing at a dead upstream still records its rule hit on the failed `Flow`.
- **The terminal event carries the trailer section**, nil when the origin sent none —
  and nil is not `[]`. It rides `end` rather than being yielded by the relay because
  the *forwarder*, not the relay, terminates the caller's stream (see the retry note
  below), and the trailers are the last thing the origin said. `ForwardResult.trailers`
  is where the fold puts them.
- `forward(...) -> ForwardResult` is a **fold** over `forwardStream` at every level of
  the decorator chain — never a second hand-synced implementation. The top-level
  buffered `forward` has no external consumer; it survives only as internal plumbing
  the decorators use when they must buffer a body (short-circuit / rewrite / breakpoint
  hold). `ForwardResult` is purely the buffered response (status / version / headers /
  body); it does **not** carry applied rules — tests assert rule hits by draining
  `forwardStream` for `.metadata`.
- Producers, in chain order:
  - **`NIOStreamingForwarder`** (base): `head` / `body` / `end`. Never `metadata` (no
    rule knowledge). It is also the only level that knows about the wire protocol:
    `forwardStream(…, clientProtocol:)` decides whether the upstream leg is HTTP/1.1
    or HTTP/2, and **every decorator must pass that value through** — one that drops
    it silently puts ruled or held exchanges back on HTTP/1.1, which for a gRPC origin
    means they stop working.
  - **`RuleApplyingForwarder`**: emits `metadata(appliedRules:)` **first** — known
    synchronously from the plan, before the connection attempt — then forwards base
    events. That ordering is what makes `appliedRules` survive a connection failure.
  - **`BreakpointForwarder`** (outermost): forwards events untouched on the fast path;
    on a matched hold it runs the request-phase hold, then consumes the base stream,
    **passing `.metadata` straight through as it arrives** (buffering only the response
    for a response-phase hold). A held exchange that then fails upstream still records
    its rule hits.
- **Projection**: `StreamRelay` / the fold build the `Flow` — `metadata` → stash
  `appliedRules` (attached to every later upsert, **including the failed one**),
  `head` → `.streaming`, `body` → append to the capped captured copy, `end`/error →
  terminal state.

## The one hard rule (back-pressure + bounded memory)

Captured body bytes are **capped observation copies** (`StreamRelay.captureCap`, 5 MB,
request and response sides alike, streaming and buffered alike) — never the
authoritative byte path, never retained beyond the bounded `Flow` projection, and only
that capped copy persists to SQLite. Wire bytes move to the client under the existing
high/low-watermark back-pressure (`RequestBodyBridge`). **The event stream must never
be treated as a replayable byte log.** Any change to this path must preserve the cap.

## Replay & the body boundary

Replay in Loom is **re-execution** (`replay_flow` re-sends the request), **not**
log-fold reconstruction — so lossless replay never depends on retaining bodies. The
architecture fully event-sources the **control/metadata plane** (small, cheap), and
keeps **bounded, capped** body capture for the inspector + SQLite, hydrated on demand.
It deliberately does **not** retain unbounded body bytes as a replayable append-only
log: that is a *resource policy* (bounded memory; infinite SSE / streams), not an
architectural inability — the same tradeoff as Charles / Proxyman. Over-cap bodies are
truncated for inspection and the truncation is surfaced (see the capped-capture rules
in [`CLAUDE.md`](CLAUDE.md)).

## WebSocket

The byte-transparent `WebSocketRelay` splice stays on the data plane — no parse, no
reframe, no buffer. `WebSocketTapHandler` emits capped frame observations that become
the `Flow`'s frame timeline without touching the splice's throughput.

---

## Appendix — design history

### The problems that forced this shape

1. **Metadata was lost on failure.** `appliedRules` rode on the `.head` response event,
   so it was dropped whenever the exchange failed *before* a response head (e.g.
   map-remote to a dead upstream) — no UI wand icon, no `appliedRules` over MCP, on
   every path.
2. **Two hand-synced production paths.** `forward` (buffered) and `forwardStream`
   attached metadata independently; drift between them is *how* problem (1) happened.

Root cause: exchange-level metadata modeled as response-level data, and success vs
failure asymmetric — success had a carrier (`.head` / `ForwardResult`), failure had
none. The fix: metadata becomes its own leading event, and success and failure are both
terminal events downstream of it.

### The idealized model (evaluated, deliberately not built)

A richer `ExchangeEvent` vocabulary was sketched — `planned`, `requestForwarded`,
`responseHead`, `responseBodyObserved`, `wsFrame`, distinct `completed`/`failed`
terminals — with an explicit **data-plane / observation-plane split** (wire bytes to
the client vs typed events the `FlowStore` folds into a `Flow`). It was **not built**:
the existing enum + `StreamRelay`'s already-capped capture + the separate
`WebSocketTapHandler` deliver the end-state properties (single failure-surviving
metadata carrier, one production path, bounded observation) without touching the hot
per-chunk path. Splitting `StreamRelay`'s single relay+build loop into two consumers
is an optional refactor with no functional gain — do it only if a second cross-cutting
observation need ever makes the abstraction pay for itself.

### Migration record (each step shipped + tested independently)

1. **DONE.** Added the leading `metadata(appliedRules:)` event to
   `UpstreamResponseEvent` as the sole rule carrier (`.head` no longer carries rules).
   `RuleApplyingForwarder` emits it first, before the network call; `StreamRelay`
   records it before any head/error and attaches it to the failed-flow upsert. Fixed
   all live streaming + rule-buffered traffic, including the reported
   map-remote-to-dead-upstream case. Covered by `AppliedRulesOnFailureTests`.
2. **DONE.** `ProxyEngine.replay` consumes `forwardStream` (folding it into the
   replayed flow) instead of the buffered `forward`; `RuleApplyingForwarder.forward`
   is likewise a fold over its own stream. Applied rules gained a single source
   (`.metadata`), and the top-level buffered `forward` lost its last external consumer.
3. **DONE.** `BreakpointForwarder.forwardStream` became the single hold implementation
   (request-phase hold → consume base stream, `.metadata` passed through as it arrives,
   response buffered only for a response-phase hold); its `forward` is a fold like the
   others. After this, **every** path carries `appliedRules` on failure. Covered by
   `AppliedRulesOnFailureTests` (`breakpoint_heldRequest_upstreamFails_stillEmitsMetadata`)
   and the existing `BreakpointTests` (hold/abort/timeout semantics preserved).
4. **NOT NEEDED — was mis-scoped.** The original "split data / observation planes in
   `StreamRelay`" step is not required by the end-state model (see the idealized-model
   note above).

`ForwardResult.appliedRules` was **removed** after steps 1–3: its only reader was the
default `forward`→stream adapter used by forward-only test stubs, so `.metadata` is now
the single representation of applied rules.

### Test matrix (what pins the contract)

- map-remote → dead upstream (streaming): failed Flow `appliedRules == [rule]`. *(the
  originally reported case)*
- response-rewrite rule → dead upstream (buffered): failed Flow carries `appliedRules`.
- replay through a matching rule → dead upstream: replayed failed Flow carries
  `appliedRules`.
- no rule + upstream error: `appliedRules == nil`, error message byte-identical to the
  pre-migration one (regression guard).
- large streaming response: memory stays bounded (observation capped, back-pressure
  intact).
- WebSocket: frames appear as observations; splice throughput unaffected.

### Out of scope (YAGNI — do not build until ≥2 real needs exist)

Durable / replayable event store, generic event bus, plugin observers, replay-by-fold,
per-event persistence of body bytes.
