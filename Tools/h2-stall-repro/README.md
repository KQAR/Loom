# h2-stall-repro — a Loom-free reproduction of the HTTP/2 upload stall

Kept for [issue #99](https://github.com/KQAR/Loom/issues/99): an HTTP/2 request body
larger than the initial 65535-byte flow-control window occasionally **deadlocks**. The
server consumes exactly one window, no further `WINDOW_UPDATE` is emitted, the client
blocks on its exhausted outbound window, and every event-loop thread goes idle.

It first showed up as a flaky CI hang in
`ProxyCoreTests / HTTP2InterceptionTests.h2RequestBodyStreamsThroughAndIsCaptured`.
**This package contains no Loom code** — SwiftNIO only — which is how we know the defect
isn't in Loom's usage. Nothing in the app or library graph depends on it; it is a
standalone SPM package that exists to be run by hand.

## Running it

```bash
cd Tools/h2-stall-repro

# Deterministic model — passes every variant. Fast.
swift run h2-embedded

# Real sockets. Needs CPU contention to reproduce: without load it passes 200/200.
for i in $(seq 1 10); do yes > /dev/null & done
swift run -c release h2-sockets 1500      # iterations
kill $(jobs -p)
```

A stalled iteration prints:

```
STALL on iteration 1454: server consumed 65535 / 200000 bytes in 9 frames
  ← exactly one flow-control window; client received 8 window grants, last outbound window 0
```

`H2MODE` selects what the server does with the body:

| `H2MODE` | Shape | Result |
| --- | --- | --- |
| `lazy` (default) | Loom's: a `NIOThrowingAsyncSequenceProducer` bridge (watermarks 4/1) whose `produceMore()` drives `channel.read()`, `autoRead` flipped off on the first DATA frame | 9 stalls / 1500 |
| `autoread` | Same pump, `autoRead` left on | 2 stalls / 800 |
| `plain` | **No bridge, no pump, no `autoRead` change.** Count the bytes, reply | 9 stalls / 1200 |

`plain` is the one that matters: the plainest possible NIOHTTP2 server stalls too, so
neither the read pump nor the `autoRead` handling is the trigger.

## What the evidence says

- The pattern Loom uses (`autoRead` off on the stream channel + demand-driven `read()`)
  is the one NIOHTTP2's own tests use — see `testReadWillCauseAutomaticFrameDelivery`
  and `testReadWithNoPendingDataCausesReadOnParentChannel` upstream.
- A client-side spy shows the client receiving 8 window grants and then
  `outboundWindowSize = 0` forever: **the server stopped emitting `WINDOW_UPDATE`**, so
  it isn't a client that ignored a grant it was given.
- Working hypothesis (consistent with all of the above, not proven):
  `NIOHTTP2.InboundWindowManager` — which describes itself as "very naive" — suppresses
  the final grant off a possibly-stale `lastWindowSize` via its
  `increment >= windowSize` check. Once the body is fully consumed and the peer is
  blocked, nothing ever fires again to recompute, so the suppression is permanent.
- Not fixed by upgrading: reproduced on nio-http2 1.45.0, the latest tag at the time.
  No matching upstream issue exists (searched open and closed, plus PRs).

## Related pieces in this repo

- `Engine/ProxyCore/Tests/HTTP2InterceptionTests.swift` — the flaky test, instrumented
  to report the stalled stage and the byte counters instead of hanging silently.
- `.github/workflows/h2-stall-hunt.yml` — dispatch-only CI workflow that hammers that
  test until a shard stalls (~1 in 100 attempts, ~6 minutes per dispatch).
- `Engine/ProxyCore/Sources/RequestBody.swift` — the real `RequestBodyBridge` this
  package models.
