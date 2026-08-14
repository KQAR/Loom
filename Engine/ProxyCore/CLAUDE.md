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

## The upstream leg matches the client's protocol (0.0.27)

Loom re-originates every exchange, and re-originating an h2 request as HTTP/1.1 is
not a neutral translation. `ClientWireProtocol` is carried from the client leg down
to `NIOStreamingForwarder`, which speaks h2 upstream when the client did. Six rules:

- **Only when the client did.** An h1 client gets an h1 upstream even against an
  origin that offers `h2`. A proxy that upgraded on its own would change which
  protocol the origin sees for traffic nobody asked it to change, and every
  h2-specific origin behaviour after that would be Loom's to explain.
- **Over TLS it is an offer; in cleartext it is a commitment — and cleartext is
  currently switched off.** ALPN asks (`["h2", "http/1.1"]`) and `http/1.1` is a
  legitimate answer, which is why both stacks are installed from the
  `ApplicationProtocolNegotiationHandler` callback rather than chosen before
  connecting. Cleartext has nothing to ask, so an h2c preface would go out **only**
  for a client that itself arrived over h2c (`ClientWireProtocol.http2Cleartext`) —
  the only evidence the origin speaks it. An h2-over-TLS request a `mapRemote` rule
  retargets at an `http://` dev server gets HTTP/1.1, which is what that server can
  read. `cleartextHTTP2Upstream` gates the h2c leg to `false`: it works and then
  stalls under load with nothing on any surface, so the leg stays HTTP/1.1, where an
  h2-only origin fails visibly instead. h2c *capture* is unaffected. Ruled-out list
  and reproduction: `docs/decisions/h2c-upstream-stall.md`.
- **ALPN is part of a context's identity.** `NIOSSLContext` fixes it at build time,
  so `ClientIdentityProviding.context(forHost:offeringHTTP2:)` caches one per
  (identity, ALPN). Offering `h2` from a context whose caller then cannot speak h2 is
  the one outcome that hangs an exchange, so the answer travels back *with* the
  context instead of being re-derived from the request.
- **An h2 connection is shared, not leased.** `UpstreamConnectionPool` keeps them in
  their own map: `lease` hands one out without removing it, `release` re-registers
  rather than parking, and the h1 bookkeeping (take-on-lease, idle timer, "is the
  slot busy") is wrong for a connection that is never idle between two requests
  because it is carrying both. `registerMultiplexed` runs **before the first stream
  is opened**, which is the only moment a duplicate can still be closed harmlessly.
- **Concurrent first requests share one connect.** `pendingHTTP2Connects` joins an
  attempt already under way, on a `Task.detached` so the connect does not inherit the
  cancellation of whichever exchange happened to start it. Measured without it: six
  concurrent first requests to one origin did six TCP connects and six TLS handshakes
  to then use one connection and close five.
- **The slot is per stream, and the version is stated.** `UpstreamExchangeSlot` is the
  handoff for *one* exchange, so each stream channel gets its own; a shared one would
  deliver one stream's head to another's caller. And `UpstreamResponseRelay` takes an
  `httpVersion` override, because `HTTP2FramePayloadToHTTP1ClientCodec` synthesizes an
  HTTP/1.1 head — deriving the version there records the conversion, not the
  connection. Exactly the rule `CapturedRequest.httpVersion` states for the client leg.

The response stack is otherwise **unchanged** on both legs — the codec hands a stream
over as `HTTPClientResponsePart`, which is what the relay already reads.

**The request writer frames per leg, and that is an encoder, not an edit.**
`writeRequest` takes the wire protocol and differs in exactly two places:

- **`cookie` is split back into one field per pair** for h2 (`HTTPUtil
  .splitCookieCrumbs`, the inverse of `coalesceCookieCrumbs`). The model keeps the
  canonical single field, because RFC 9113 §8.2.3 requires that form before the
  fields reach "an HTTP/1.1 connection, **or a generic HTTP server application**" —
  so the origin's application sees one field either way, and the crumb split is below
  the semantic layer, like a body's DATA-frame boundaries. What it buys is HPACK: the
  dynamic table defaults to 4096 bytes and charges `name + value + 32` per field, so
  a merged kilobyte of cookie never fits and is re-sent as a literal on *every*
  request, where crumbs are indexed once. (Reasoned from the table size, not measured
  — but the split itself is pinned: remove it and `theH2LegSplitsCookieCrumbsBack`
  fails.) The client's original grouping is gone by then, so this is a reconstruction
  per cookie-pair, not a restoration.
- **`Transfer-Encoding` is never set on an h2 leg** (RFC 9113 §8.2.2 — connection
  specific, MUST NOT appear, receiver MUST treat as malformed). Belt-and-braces and
  known to be so: NIOHTTP2's client codec strips it anyway, measured by removing the
  guard and watching nothing change. It stays because not emitting a forbidden field
  is ours to get right, not a library's to paper over.

## Trailers are forwarded and captured on both legs (0.0.27)

A trailer field section is where gRPC returns its result (`grpc-status` /
`grpc-message`, after the body), and Loom dropped it in both directions: the request
writer sent `.end(nil)`, the response writer sent `.end(nil)`, and the capture had
nowhere to record one. Four rules:

- **Nil and empty are different** (`CapturedRequest.trailers` / `CapturedResponse
  .trailers`, `UpstreamResponseEvent.end(trailers:)`). No trailer section is not an
  empty one, and a render that collapsed them would grow a `trailers: []` key on
  every ordinary exchange.
- **A streamed request's trailers are only knowable after the body**, so they travel
  in a `RequestTrailers` box the bridge fills *before* `finish()` — read it only
  after the chunk sequence has ended. `RequestBody.collect()` returns body **and**
  trailers together, because draining is the act that makes the second one knowable;
  a caller that took only the bytes is how every buffering decorator used to eat them.
- **A buffered body carrying trailers is re-framed chunked upstream**, since a
  `Content-Length` message has nowhere to put them (RFC 9112 §7.1.2). One case is
  still dropped and is not silent: a *streamed* body whose client declared a
  `Content-Length` and then sent trailers anyway — legal over h2, impossible over h1,
  and the framing was chosen before the first chunk went out. The capture keeps them.
- **A trailer is not a header.** They stay a separate field on the model, a separate
  block in the renders, a separate section in the Inspector, and a separate list in
  `FlowComparison` — a field that moved between the head and the trailers is a real
  difference, and merging them would report it as none.

## Upstream connections are pooled

`UpstreamConnectionPool` keeps upstream sockets alive between requests, keyed by
`(host, port, isTLS, mTLS identity)`. Before it, `forwardStream` built a
`ClientBootstrap` per call and the response relay closed the channel on `.end`, so
**every intercepted HTTPS request paid a fresh TCP connect and TLS handshake** —
measured against a real test API at ~96 ms on top of a 20 ms server round trip, i.e.
the proxy costing five times the thing it proxied. That is the entire reason Loom
felt slow next to Charles, which pools; a phone on the same Wi-Fi saw it doubled.

Seven rules, each of which is a way to get this wrong rather than a preference:

- **Keep-alive is not enough to pool a connection.** `UpstreamExchangeSlot.responseIsReusable`
  also requires framing — a `Content-Length`, chunked, or a status/method that
  carries no body. A response delimited by the connection *closing* ends with the
  socket, so parking one hands the next request something already going away.
- **A 1xx is not the response** (RFC 9110 §15.2). The decoder delivers `100
  Continue` as a complete head+end message, and completing the exchange on that
  end released the connection into the pool **while the final response was still
  on the wire** — the worst schedule then delivers one request's response to the
  next. Interim heads and their ends are swallowed in the slot; 101 is deliberately
  not interim (it ends HTTP framing; the forwarder strips `Upgrade`, so an origin
  sending one is answering a request Loom never made) and can never pool.
- **A leased connection may be dead, so the retry is load-bearing — and it is
  gated on RFC 9110 §9.2.2.** A pooled attempt that fails **having yielded
  nothing** is retried once on a fresh connection *if* the method is idempotent
  or the request's final flush never succeeded (so the origin cannot have read a
  complete request). A POST that was fully written and then went dark may have
  been acted on; re-executing it is the caller's decision, never the pool's.
  `UpstreamAttemptFailure` carries both facts (`didYield`, `requestWritten`), and
  the relay reports the outcome instead of finishing the caller's stream itself —
  a relay that had already finished it would have spent the choice.
- **Only a `.bytes` body may lease.** The retry needs a request it can re-send; a
  `.stream` body is a live back-pressured pull from the client, consumed exactly
  once. Streamed requests connect fresh and still *release* into the pool.
- **The final `end` flush is awaited.** With `promise: nil` a write to a socket the
  origin had already closed was swallowed and the exchange then waited forever on a
  response that could not arrive. This is where staleness surfaces — and its result
  is kept: a response that completed while the request's body never fully left
  (a server answering 413 early) is delivered, but the connection is closed, not
  released, because from the origin's side it is still mid-request.
- **The stream's `onTermination` must not close a connection that was handed back.**
  `ActiveUpstreamBox` is cleared before the release, so a consumer walking away
  mid-response closes the socket and a consumer finishing normally does not.
- **A client-certificate write drains the identity's parked connections**
  (`UpstreamConnectionPool.drain(identityLabel:)`, called from the engine's
  certificate writes). The pool key carries the identity's *label*, and an
  in-place PKCS#12 edit changes neither — `ClientCertificateConfig` already drops
  its cached `NIOSSLContext` on mutation, and connections handshaken under the
  old certificate are the other copy of the same stale state; under steady
  traffic they would never idle out.

A failure that arrives **before the exchange arms** (a fresh connection whose TLS
handshake runs to failure first) is *held* by the slot and replayed at `arm`, so
`UpstreamTLSError` gets NIOSSL's real error to name instead of a bare
`connectionClosed` reconstructed from `isActive`.

`UpstreamResponseRelay` is plainly `Sendable` as a result: one relay serves many
exchanges, and what used to be its per-exchange handler state is the slot's.
`NIOHTTPResponseDecompressor` is safe to keep across responses (it builds a decoder
per `.head` and drops it on `.end`) — pinned by a test, because a stale decoder
would surface as a corrupt body several requests later, nowhere near the cause.
`ProxyEngine.stop()` drains the pool: the switch being off is a promise that Loom
is not holding sockets open at anyone's origin.

## The sniff deadline schedules a question, it never answers one

`TunnelSniffHandler` classifies a tunnel from its first bytes. The 150 ms deadline
exists only for server-first protocols (SSH, SMTP, IMAP, MySQL, PostgreSQL), which
send nothing until the *server* greets. It used to **conclude** on expiry — declare
the tunnel `.opaque` and relay it byte-for-byte, unread — and that was wrong for
every case it could reach.

The proof is in `ProtocolSniff.classify`: it returns `.opaque` on the **first byte**
of anything unrecognised. So `.needMore`, the only state that survives to the
deadline, means exactly one of two things, and the timer was a wrong answer to both:

- **silence** — a server-first protocol, *or* a client that opened the tunnel ahead
  of need (OkHttp and Chrome both pre-connect: `CONNECT`, take the ack, park it,
  send the ClientHello seconds later);
- **an unfinished prefix of something recognisable** — a lone `0x16`, part of the h2
  preface, a method token with no space yet. Client-first by demonstration; merely
  late. A ClientHello split across segments is ordinary on a lossy link.

Expiry now starts a **speculative upstream connection** and lets whichever side
speaks next settle it. Five rules:

- **It writes nothing.** Anything the client already said stays buffered in the
  sniffer; sending it would rule out the MITM the tunnel may still need.
- **A server greeting reuses that connection** (`serverSpokeFirst`), because the
  greeting has already arrived on it. `probe` is cleared *before* the handler is
  removed — `handlerRemoved` closes a live probe, and this is the one path where the
  probe is the connection being glued rather than one to discard.
- **Client bytes drop it** and route normally. One wasted connect, only on a tunnel
  that had already gone quiet past the deadline.
- **A probe that can't connect is not a verdict.** The client may still be about to
  send a ClientHello, and the real connection made for it reports its own failure
  through `UpstreamConnectionError` rather than as a silently unread tunnel. It is
  logged at debug, though — in the one corner where nothing else ever reports (a
  client that never speaks against an origin that is down), that line is the only
  trace the connection existed. A probe that connects and then dies silently
  clears itself (`probeDied`) without becoming a verdict either.
- **Both ends pause reads across the splice.** Bytes reaching the end of a pipeline
  with no glue in it yet are dropped without a sound, and the upstream side has by
  definition already started talking — `UpstreamGreetingProbe` buffers *everything*,
  not just the first read, for the same reason. The whole guarantee currently rests
  on the splice's future chain running synchronously on one loop;
  `aBannerSplitAcrossTheSpliceArrivesWhole` pins the observable property so a
  future asynchronous step fails a test instead of dropping banner bytes.

**The h2c preface is a verdict, not a relay.** `PRI * HTTP/2.0` reads exactly like
an HTTP/1 request line, so it always had to be separated out before the request-line
test — it just used to answer `.opaque`, on the reasoning that h2 needs a negotiated
ALPN. It does not: ALPN only *says* h2. `.h2c` now routes to
`MITMPipeline.installCleartextHTTP2`, which is the **same** `installHTTP2` the ALPN
branch takes (one definition, for `MITMPipeline`'s own reason), differing only in
`upstreamTLS` — so the h2↔h1 codec, the raised `SETTINGS_MAX_HEADER_LIST_SIZE` and
`HTTP2ConnectionErrorReporter` all apply to cleartext h2 too, and every one of those
was a bug before it was a handler. Only the first 14 bytes are matched, not the full
24: enough to be unambiguous, and inside `ProtocolSniff.maxBytes`.

The host is recorded in `TunneledHostLog` only **after the splice stands** — on the
failure path both ends are closed, and listing the host as "relayed" would claim
activity the operator's client never got. Silence from both sides stays undecided
and is deliberately **not** recorded: nothing is being missed (no traffic has
happened), and listing it would put every warm tunnel a browser holds in front of
an operator asking why a host went unread.

## An error SwiftNIO raises is Loom's to answer

A pipeline with no error handler turns a codec failure into an **infinite wait**,
which is the worst thing a debugging proxy can do: the operator blames their app,
and the capture agrees with them. Two places raised errors that reached the end of a
pipeline and stopped existing; both are now handled, and any new pipeline needs the
same treatment.

- **Client-facing TLS** (`ClientTLSFailureReporter`, between `NIOSSLServerHandler`
  and ALPN). A client that refuses Loom's leaf sends a fatal alert and hangs up
  before any request — no flow to attach the failure to, so it lands in
  `TunneledHostLog` as `.clientHandshakeFailed` with the handshake error in
  `detail`. Only `NIOSSLError.handshakeFailed` counts: an unclean shutdown is an
  ordinary mid-stream hangup, and recording it as "the client refused Loom" would
  put noise on the one surface an operator reads to find a missing host.
- **Intercepted HTTP/2** (`HTTP2ConnectionErrorReporter`, at the tail of the
  *connection* channel). For a connection-fatal codec error it records
  `.protocolError` and then **closes**, because HPACK is per-connection state
  (RFC 7541 §2.3): a header block that could not be decoded leaves the dynamic
  table desynchronised, so nothing after it can be read either. RFC 9113 §5.4.1 —
  signal the connection error and close; carrying on is not an option, and staying
  silent is what produced a phone spinning forever. **Not every error reaching it
  is that error**, and treating them alike was measured as a live defect within a
  day of shipping (a fully-captured host listed as `protocolError` off a teardown
  RST): `NIOHTTP2Errors.StreamError` passes through untouched (RST_STREAM already
  answered it; closing would kill every other in-flight stream), and transport
  teardown (`NIOSSLError`/`IOError`/`ChannelError`) closes without recording.
  Anything unrecognised **fails closed into the fatal tier** — a wrongly-closed
  connection is retried by the client, a wrongly-kept one hangs forever.

Both reporters take a `TunneledHostLog` in their initialiser (defaulting to
`.shared`) so tests assert against their own instance instead of resetting the
process-wide one out from under a parallel suite. And the verdicts they record are
**recoverable**: a completed client handshake on the same host:port clears
`clientHandshakeFailed`/`protocolError` (`TunneledHostLog.clearClientVerdicts`) —
the operator who just installed the CA sees the entry and the orange icon go,
instead of haunting until relaunch; a still-broken codec re-records itself on the
next failure, one connection later.

## A proxy must not be stricter than the origin

`MITMPipeline.maxHeaderListSize` replaces SwiftNIO's advertised
`SETTINGS_MAX_HEADER_LIST_SIZE` of 16 KB (`HPACKDecoder.defaultMaxHeaderListSize`,
whose own comment calls the value "somewhat arbitrary"). Any limit Loom enforces
that the real server does not becomes a failure that exists *only while Loom is in
the path*.

Measured: an app whose session cookies had grown to 15–31 KB refreshed its home
screen and the request vanished — the origin answered the same 20 KB header in
58 ms, Loom's HTTP/1.1 path in 196 ms, and Loom's h2 path not at all. One line
reproduces it: `curl --http2 -x 127.0.0.1:9090 -H "Cookie: k=$(python3 -c "print('a'*20000)")"`.

**One caveat that is upstream's, and is why the error handler matters as much as
the limit.** SwiftNIO builds its frame decoder in `handlerAdded` with the HPACK
default and only raises it on `localSettingsChanged` — i.e. when the peer
*acknowledges* Loom's SETTINGS (RFC 9113 §6.5.3). So on a brand-new connection the
16 KB limit still applies until the ACK lands, and a client that sends its first
request without waiting (RFC 9113 §3.4 explicitly allows this) can still trip it.
Measured after the fix: the steady-state case answers 200, and the first-request
case fails in 80 ms with a closed connection instead of hanging for 20 s. Closing
that window needs a change in swift-nio-http2, not here.

**One boundary this deliberately does not close.** Loom→origin is always
HTTP/1.1, and the encoding direction has no limit (NIO's llhttp does not bound
outgoing headers), so the 1 MB request head goes out — but an origin's *h1
front-end* can refuse the coalesced giant Cookie line (nginx's
`large_client_header_buffers` defaults to 8 KB) where the same client direct over
h2, crumbs split per RFC 9113 §8.2.3, gets through. Unlike the hang this section
fixed, that failure is visible — a 4xx, captured and forwarded — so it reads as
what it is. A fix would mean speaking h2 upstream, which is its own project.

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

## The connection is recorded, not just the message

`FlowTransport` carries what the exchange travelled over — origin address, pool
reuse, both TLS legs, the response's encoded size — and three positions in the
pipeline are load-bearing rather than convenient:

- **`UpstreamEncodedBodyCounter` sits between `addHTTPClientHandlers()` and
  `NIOHTTPResponseDecompressor`.** That is the only point where the body is both
  framed into parts and still encoded. Below the decompressor it would be a
  second, worse copy of the captured length; the response's own `Content-Length`
  is not an alternative, because it is stripped on the way out *and* absent on
  every chunked response.
- **`UpstreamTLSObserver` sits directly after `NIOSSLClientHandler`**, records on
  `TLSUserEvent.handshakeCompleted`, and **verifies nothing**. NIOSSL's custom
  verification callback is the other route to the peer chain and taking it would
  mean owning trust evaluation for every upstream connection; reading the
  certificate after NIOSSL has validated it costs one DER parse *per connection*
  and risks nothing.
- **`UpstreamTLSObserver` starts its handshake clock at `channelActive`, not at
  `handlerAdded`.** The pipeline is built before the socket connects, so timing
  from construction folds the TCP connect into the handshake — the two numbers
  `ConnectionSetup` exists to keep apart. Durations use `NIODeadline` (monotonic):
  a wall clock can step backwards mid-handshake and yield a negative one.
- **DNS is timed by an extra resolution, and the connector is left alone.**
  `measureResolution` runs one `getaddrinfo` off the loop (`@concurrent` — a
  blocking syscall on a cooperative-pool thread is the defect `ProcessResolver`
  documents), then the bootstrap resolves and connects exactly as before. Handing
  the resolved address to `connect(to:)` would skip the second lookup and also
  skip Happy Eyeballs across the A/AAAA answers, which changes how Loom behaves on
  every dual-stack network to make a number prettier. The first resolve pays the
  real cost, which is what is reported; the bootstrap's is served from the cache.
  A resolver failure is swallowed — the bootstrap reports the real error a moment
  later.
- **The transport is evaluated when the head arrives, not when the exchange arms**
  (`UpstreamExchangeSlot.Armed.transport` is a closure). On a fresh connection the
  handshake has not finished at arm time — NIOSSL buffers the request write until
  it has — so an earlier read reports nil on exactly the connections it matters
  for.

It is emitted as **at most two `.transport` events, merged not replaced**: the
head instalment carries everything the connection knows, the end instalment
carries the byte count, which is not a number until the body finishes. Every
consumer folds (`StreamRelay`, `collect()`, `BreakpointForwarder`, replay); a
consumer that assigned would keep only whichever arrived last.

## A capped capture is never silent

- `CapturedRequest`/`CapturedResponse.fullBodyBytes` records the true wire size whenever `body` is
  only a prefix (`isBodyTruncated`); `Flow.webSocketDroppedMessages` counts frames the WS cap
  dropped.
- The fact must surface everywhere: `get_recent_flows` (`captureTruncated`), `get_flow_detail`
  (`bodyCaptureTruncated` + `bodyBytesOnWire`, `webSocket.framesNotRecorded`), HAR (`bodySize` =
  wire size + `_bodyTruncated`), the Inspector body pane — and **`diff_flows`**, which is the one
  place where missing it produced a wrong answer rather than a thin one: two bodies capped at the
  same byte count have identical prefixes whatever their tails did, so the comparison reported a
  confident "no difference". `FlowComparison.compareBodies` takes both sides' `fullBodyBytes`, a
  matching pair of prefixes is `.tailNotCaptured` rather than `nil`, and `FlowComparison.isPartial`
  is what both surfaces qualify "identical" with.

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
   anyway). The `@unchecked` on these handler *types* is what remains, and its removal path really
   is `NIOAsyncChannel` — not scheduled.

   **What is no longer part of that rework: the pipeline-construction warnings.** This entry used to
   bundle the ~24 "conformance of X to Sendable is unavailable" / "capture of X in a `@Sendable`
   closure" warnings into the same `NIOAsyncChannel` job and call the whole thing unscheduled. That
   was wrong, and expensively so — the warnings were purely about *where handlers were built*, and
   they are all gone now (0 warnings in this module) without touching the handlers themselves. Two
   idioms did it, and **new pipeline code must use them**:

   - **Build handlers inside `channel.eventLoop.makeCompletedFuture { … }`, adding them through
     `channel.pipeline.syncOperations`.** That body is *not* `@Sendable` (unlike
     `EventLoopFuture.flatMap`'s), so a non-`Sendable` handler constructed in it never crosses an
     isolation boundary. `syncOperations` requires being on the channel's loop, which every
     `channelInitializer` and every channel-handler method already is. This replaced every
     `pipeline.addHandler(handlerBuiltAbove)` chain in `ProxyServer`, `ReverseProxyServer`,
     `ProvisioningServer`, `MITMPipeline` (all four installers) and `TunnelFlow.glue`.
   - **`eventLoop.assumeIsolated()` / `future.assumeIsolated()` when a callback captures
     `ChannelHandlerContext`.** `context` is not `Sendable` and the plain `execute` / `scheduleTask`
     / `whenComplete` overloads take `@Sendable` closures. The isolated variants take ordinary ones
     and `preconditionInEventLoop()` at the call — so the assumption these handlers already run on
     ("everything here is on this channel's loop") becomes a checked one instead of a comment.
     Used in `TunnelSniffHandler` (×2), `SOCKSConnectionHandler.write`, `ProvisioningServer.respond`.

   One thing that could **not** move inside: `NIOStreamingForwarder` must resolve the upstream
   `NIOSSLContext` *before* connecting, because that resolution is where a configured-but-unloadable
   client identity fails, and that error has to reach the caller naming the identity rather than
   being wrapped in a handshake story. `NIOSSLContext` is `Sendable` and `NIOSSLClientHandler` is
   not, so the context is captured and the handler is built inside. Keep that split.
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
