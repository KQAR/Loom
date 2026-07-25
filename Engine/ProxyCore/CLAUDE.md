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
