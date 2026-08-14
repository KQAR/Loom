# The h2c upstream leg is built, works, and is switched off

*Recorded 0.0.27. The switch is `NIOStreamingForwarder.cleartextHTTP2Upstream`.*

Loom re-originates every exchange, and 0.0.27 made the upstream leg match the
protocol the client spoke instead of always being HTTP/1.1. Over TLS that shipped and
is verified against real origins. **Cleartext h2c is built and gated off**, because it
intermittently stalls in a way that leaves nothing on any surface.

This file exists so the next attempt starts from the ruled-out list rather than from
the beginning.

## What works

Against a real out-of-process cleartext HTTP/2 origin, driven by hand:

- The whole gRPC shape completes: `HTTP/2 200`, body, and `grpc-status: 13` /
  `grpc-message` delivered to the client as response trailers.
- The `cookie` crumb split reaches the wire — the origin's HEADERS frame carries
  `["a=1", "b=2", "c=3"]` where the model holds one merged field.
- A SwiftNIO h2 client through Loom: 3 of 3 succeeded, all three exchanges sharing one
  upstream connection.

## What fails

Under concurrent load. The reproduction is `H2CConcurrencyTests` (checked in,
`.disabled`): 40 concurrent CONNECT tunnels, each an h2c client leg to an h2c origin,
run **alongside the rest of `ProxyCoreTests`** — the load is part of it, because the
test passes when run alone.

With a 30 s per-request deadline:

| measurement | value |
|---|---|
| requests captured as flows | 39 / 40 |
| of those, answered by the origin | 38 |
| answers that reached the client | a handful |
| response writes reporting a failure | **none** |

By hand through the app, with a byte logger on the origin, the same stall looked
different and worse: the origin received the connection preface, Loom's SETTINGS and a
SETTINGS ACK — and then **no HEADERS frame at all**, on a connection that stayed open.
Roughly one attempt in three succeeded.

## Ruled out, each by a measurement

- **Upstream connect coalescing** (`pendingHTTP2Connects`) — disabled, still stalls.
- **h2 connection sharing** — one connection per exchange, still stalls.
- **A first-stream activation race** — a 50 ms delay before creating the stream
  changes nothing.
- **The `cookie` crumb split** — disabling it does not help, and it is not the
  variable: single-pair and multi-pair cookies both stall.
- **Rules and breakpoints** — the app had none armed; the decorators are pass-through.
- **Loom's own h2c server leg failing to send SETTINGS** — captured off the wire; it
  sends them.
- **The client leg losing the request** — it delivers `.head` and `.end` to
  `TLSInterceptHandler`, and the flow is captured with the right URL.
- **Swallowed response-write failures** — the three `HTTPUtil` response writers now
  report failures instead of dropping them (a fix worth keeping either way), and they
  report none.

## Two traps for whoever picks this up

**The numbers move with the deadline.** Taking the per-request deadline from 5 s to
30 s took captured flows from 30 to 39. So some of what reads as loss is starvation of
a four-loop `EventLoopGroup` shared by 40 clients, the engine and the origin. *"Slow"
and "lost" are currently the same measurement*, and separating them — a raw byte
counter on the client tunnel — is the first thing to do, before trusting any of the
counts above.

**os_log drops lines here.** Both `log stream` and `log show` lost trace lines from
the middle of an exchange under this load, which sent one round of diagnosis after a
phantom ("`writeRequest` was never entered" — it was). Use a file-based trace, or make
the assertion out of counters the test can read.

## Two dead ends, so they are not re-walked

- **Awaiting the request head's write.** `channel.write(...)` without a flush completes
  only *when* the flush happens, and the flush is the `.end` that follows — so awaiting
  the head deadlocks every request. The swallowed encode error it was meant to surface
  is real but must be surfaced some other way.
- **Moving the h2 pipeline setup out of `channelInitializer`.** The TLS path configures
  h2 from the ALPN callback on a live channel, so doing the same after `connect()`
  returns looks like the tidier arrangement. Measured: the origin then receives nothing
  at all — 0 of 5 requests — against a live origin answering a direct client 200. The
  likely reason is the connection preface, which `NIOHTTP2Handler` writes on
  activation and evidently not when added to an already-active channel.

## Why off rather than shipped with a caveat

An h2c client whose exchange goes upstream as HTTP/1.1 against an h2-only origin gets
a **visible** failure — a parse error recorded on the flow. The stall gets a hang with
no error, no log line and a captured flow frozen at status 0, which is the exact
shape `TunneledHostLog`, `RefusalLog` and the head-time `observe` all exist to prevent.
Given the choice between the two, the visible one ships.

h2c **capture** is unaffected and stays on: the preface is sniffed, the exchange is
recorded, and the operator sees the request. Only the upstream leg is gated.
