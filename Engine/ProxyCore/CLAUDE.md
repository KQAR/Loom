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
not a neutral translation: a gRPC origin is h2-only and refuses an h1 request
outright. `ClientWireProtocol` is carried from the client leg down
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
- **An h2 connection is shared, not leased.** `lease` hands one out without
  removing it; `release` re-registers rather than parking. The idle watch still
  applies — sharing is not immortality — and a long-lived stream keeps the socket
  because idle means nothing running *and* nothing started or finished for the
  timeout. A first-byte PING fail must evict before `registerMultiplexed`, or the
  retry is handed the same dead incumbent. Registration runs **before the first
  stream is opened**, the only moment a duplicate can still be closed harmlessly.
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
- **A leased connection may be dead, so the retry is load-bearing — and the
  evidence it is gated on is *what killed the connection*, not whether the write
  landed.** A pooled attempt that fails **having yielded nothing** is retried once
  on a fresh connection when the method is idempotent, when the final flush never
  succeeded, or — the case that was wrong until 0.0.28 — when the failure is
  **transport teardown** (`NIOStreamingForwarder.mayRetry` / `isTransportTeardown`,
  the same tiering as `HTTP2ConnectionErrorReporter.classify`).

  The old rule allowed a non-idempotent retry only on `!requestWritten`, reading a
  successful final flush as proof that the origin had read a complete request.
  **It proves no such thing**: a write to a socket whose peer has already closed
  succeeds, landing in this host's send buffer — FIN ends only the peer→us
  direction — and the RST arrives later, on the read. So an origin reaping an idle
  keep-alive connection produced `requestWritten == true` for a request no origin
  saw, and a POST on that socket failed while the identical POST on a fresh one
  succeeded. That is the idle-connection race every HTTP client has to answer, and
  it surfaced as `aStalePoolNeverFailsAPost_whoseWriteNeverLanded` failing
  intermittently on CI (`errno 54`, ECONNRESET on read) and never locally.

  What still holds: anything that is **not** the transport going away — a protocol
  error, a decoder failure — does not re-run a non-idempotent method, because those
  can follow an origin having read and acted. The residual risk is stated rather
  than hidden: an origin could read, act, and reset without sending a byte, which
  Loom cannot distinguish from a reap; the rule it replaces failed *every* reaped
  POST to avoid that one. A **fresh** connection keeps the strict rule — there a
  failure after a successful write genuinely may mean the origin acted.
  `UpstreamAttemptFailure` carries all three facts (`didYield`, `requestWritten`,
  `underlying`), and the relay reports the outcome instead of finishing the
  caller's stream itself — a relay that had already finished it would have spent
  the choice.
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
load-bearing (see the CONNECT-surgery note [below](#known-issues-engine-scoped)). Not worth it. Re-measure
before reopening.

## Known issues (engine-scoped)

Moved here from the root `AGENTS.md`, which loads in full at the start of every session while
these six are only wrong to not know when you are editing this module. **The version-stamp rule
travels with them**: every entry carries the version it was last *verified* in, because each is a
claim about tooling, an OS or an upstream library, all of which move — and an unstamped entry is
indistinguishable from one that stopped being true two releases ago. Move a stamp when you confirm
an entry; when you cannot confirm it cheaply, say so in the entry rather than leaving the stamp
stale. Five of the six are re-checked mechanically by `scripts/verify-known-issues.sh`; the sixth
(CONNECT ordering) can only be checked by the interception suite, which is why it says so.

- **CONNECT surgery is order-sensitive.** *(verified 0.0.24 by the interception suite, which is the only thing that can check an ordering — no grep proves it.)* In `ProxyHandler.interceptTLS` the swap runs on `.end` (after the decoder emits the CONNECT parts); handlers must conform to `RemovableChannelHandler`, the HTTP encoder is removed before TLS writes, and TLS is inserted at the pipeline head. Changing this order reintroduces `WRONG_VERSION`/decode crashes.

- **Root CA is stored in a file, not the Keychain.** *(verified 0.0.24.)* `FileCAStore` keeps the CA (cert + key) in a 0600 `~/Library/Application Support/com.loom/ca-store.pem` — same as Charles/mitmproxy. This is deliberate: a Keychain item's ACL is bound to the app's code signature, so every ad-hoc rebuild during development re-prompted for the login password on the CA read. A file has no ACL → no prompt. `ProxyEngine.migratedCAStore()` migrates a legacy Keychain CA into the file once (preserving an already-trusted CA); `KeychainCAStore` remains for reference only.

- **HTTPS leaf certs must use ≤20-octet serials.** *(verified 0.0.24.)* `Certificate.SerialNumber()` can yield 21 octets (RFC 5280 violation) which Secure Transport rejects with `-1015 "cannot decode raw data"` — silently breaking interception for ~half of hosts while browsers (lenient BoringSSL) still work. `CertificateAuthority.makeSerialNumber()` clears the top bit; don't revert to the default initializer.

- **h2 `cookie` crumbs are one field in the model, split only on the way out over h2.** *(verified 0.0.24; the second leg landed 0.0.27.)* RFC 9113 §8.2.3 lets an h2 client split `cookie` into one field per cookie (Chrome does) and requires an intermediary to concatenate them with `"; "`; `HTTP2FramePayloadToHTTP1ServerCodec` does not, and RFC 6265 §5.4 allows exactly one field, so origins read the first crumb and dropped the rest — silently, and looking nothing like a proxy bug (**a signed-in site comes back signed out**). `HTTPUtil.coalesceCookieCrumbs` runs in `TLSInterceptHandler` on `.head`, i.e. **before capture**, so the merged field is what every surface holds; `HTTPUtil.splitCookieCrumbs` re-splits it when the request goes out over h2, which is an encoder, not an edit. A single `cookie` header (every h1 client) is returned untouched. Why the merged field is the canonical *message* rather than a concession to one leg, and what keeping crumbs in the model would have cost: [`docs/decisions/h2-cookie-crumbs.md`](../../docs/decisions/h2-cookie-crumbs.md).

- **The forwarder strips Content-Encoding/Content-Length.** *(verified 0.0.24.)* `NIOStreamingForwarder` runs a `NIOHTTPResponseDecompressor`, so the bytes reaching the client are already decompressed; it drops those two headers on `.head` (`HTTPUtil.sanitizeDecodedResponseHeaders`) — otherwise the client re-decodes plaintext and fails with -1015.

- **SSL scope persists in UserDefaults** *(verified 0.0.24.)* (`com.loom.sslScope`), so HTTPS interception survives relaunch. Without it every launch reset to disabled → all HTTPS blind-tunneled → nothing captured. The test-seam engine passes `InterceptionConfig(defaults: nil)` to stay hermetic.


- **A host whose first h2 header block Loom cannot read is served HTTP/1.1, and every flow says so (0.0.27).** *(verified 0.0.27 — reproduced deterministically, three ways.)* SwiftNIO's HPACK decoder keeps the library's 16 KB `maxHeaderListSize` until the peer ACKs `initialSettings`, and RFC 9113 §3.4 lets a client send its first request before that (OkHttp does) — so a first request whose *decoded* header list exceeds 16 KB dies as a connection-level `COMPRESSION_ERROR`. Still present in nio-http2 **1.45.0**, no knob on `NIOHTTP2Handler.Configuration`; the measurement, the repro (`Tools/h2-hpack-repro`) and why the trigger is worded the way it is: [`docs/decisions/h2-header-block-downgrade.md`](../../docs/decisions/h2-header-block-downgrade.md).

  So Loom stops offering ALPN `h2` to that host (`HTTP2DowngradeRegistry`, read by `CertificateAuthority.serverContext`), and the client negotiates HTTP/1.1 by itself. Five rules. The trigger is **`compressionError` or `NIOHTTP2Errors.ExcessivelyLargeHeaderBlock`** — a frame-size or protocol violation is the client's bug and must not be hidden behind a protocol change — and **only before any stream frame has been delivered**, which is the one moment the pre-ACK limit applies. The TLS context cache is keyed on the **lowercased** host, or a second CONNECT with different case keeps advertising `h2`. The cached per-host `NIOSSLContext` is **dropped** when a host is added, or it goes on advertising `h2` for the life of the entry (the stale-context trap `ClientCertificateConfig` documents). It is **session-scoped and never persisted**: the condition depends on today's cookie size and a library version. And the exchange is **marked** — `FlowTransport.clientProtocolDowngraded`, rendered for the agent and drawn in the Inspector in the warning colour — because `CapturedRequest.httpVersion` then reads `HTTP/1.1`, which is true of what happened and false about what the app would have done.

- **The `Thread Sanitizer (ProxyCore)` job is suppressed, not re-run, and the suppression is proven live.** *(verified 0.0.19.)* One entry in `Tools/tsan/suppressions.txt` covers the upstream report (`swiftlang/swift#57803`), loaded by both TSan workflows through `TEST_RUNNER_TSAN_OPTIONS` as an *environment variable* of `xcodebuild` — **the two wrong forms both failed silently**, leaving an unprotected run that reads exactly like a clean one, which is why the channel is spelled out here rather than left to whoever edits the workflow next. `Tools/tsan-canary/` proves the suppression still reports a real race, and a suppressed report is still counted (`print_suppressions=1` + a `::notice::`). One reading caveat that is not about races at all: `xcodebuild`'s `Executed 0 tests` tail line counts XCTest cases, of which this Swift Testing suite has none. How to read a red job is in the root [`AGENTS.md` § CI](../../AGENTS.md#ci); the three real defects found while chasing it, and why each suppression choice is what it is: [`docs/decisions/tsan-continuation-race.md`](../../docs/decisions/tsan-continuation-race.md).

- **TSan runs locally through `scripts/tsan-local.sh` — except right now it does not, and that is a bundle-load failure rather than a signal.** *(the mechanism was verified 0.0.24 — macOS 26.5 / Xcode 26.3 / arm64, 464 tests in 78 suites, zero races, suppressions loaded. **Re-run 0.0.27 and it fails on this machine**, at the commit before that round's changes too: `Failed to create a bundle instance representing … ProxyCoreTests.xctest`, i.e. `@rpath/LoomProxyCore.framework` not loaded, before any Loom code runs. Not chased further — the CI job is unaffected and is the one that gates. Details and the clang-version suspect: [`docs/decisions/tsan-local-runtime.md` § Later note](../../docs/decisions/tsan-local-runtime.md#later-note-0027-the-local-run-stopped-working-again-for-a-different-reason).)* What the script does and why: the segfault in TSan's own init is a bug in the **sanitizer runtime shipped with the toolchain**, not an OS limitation (CI runs `macos-26-arm64` and is green), so a local run needs the newer runtime already on the machine — the separately installed Command Line Tools carry a newer clang, the runtime is `@rpath`-loaded, and `TEST_RUNNER_DYLD_LIBRARY_PATH` reaches the test process. Three rules survive that. **CI must not copy any of it**: its toolchain is already fixed, and pointing it at a Command Line Tools path would add a dependency on the runner image's layout for no gain. **A local-only race is an ABI-mismatch suspect first**, since the instrumented code comes from Xcode's clang and the runtime from a newer one. And **one signature is not this bug at all**: TSan aborts when it cannot read its suppressions file, which xcodebuild reports with the *same* `The test runner crashed before establishing connection` line — the discriminator is a trailing `abort() called`, the cause is TCC, and the script stages the file into `$TMPDIR` rather than pointing at it in place.

- **The h2 upload deadlock is upstream's, and `Tools/h2-stall-repro/` reproduces it with SwiftNIO alone** — [#99](https://github.com/KQAR/Loom/issues/99), unfixed. *(the instrumentation is verified 0.0.24 — the suite runs green, which is the ~99 % case and says nothing either way; the stall **signature** was last observed in 0.0.18, and re-confirming it means re-running the repro until it trips — it was re-run after the 0.0.24 `Mutex` change and still stalls with the documented signature.)* Roughly 1 % of the time an HTTP/2 request body over 65535 bytes stalls. It is **not Loom's usage**, which is what the standalone repro establishes and what keeps this from being re-diagnosed as a forwarder bug every time it goes red. `HTTP2InterceptionTests`'s h2 upload test is instrumented to fail at 25 s with the stalled stage and byte counters, so the signature is readable at a glance rather than inferred from a timeout. The tell itself is in the root [`AGENTS.md` § CI](../../AGENTS.md#ci); the full record, including the rule this entry used to give and why it was backwards: [`docs/decisions/h2-upload-stall.md`](../../docs/decisions/h2-upload-stall.md).

### The SSL scope and the capture-drop stage

The whitelist decision itself, and what a rule-dropped or unread exchange looks like from
outside, are in the root [`AGENTS.md` § Known Issues](../../AGENTS.md#known-issues); the human
surfaces are in [`Features/AppFeature/CLAUDE.md`](../../Features/AppFeature/CLAUDE.md). What
follows is what the engine must keep true.

- **`dropFromCapture`'s five rules, and the reasoning for each — the rule-versus-`Route` choice, the group check that was spelled three times, and why dropping beats filtering on read — is in [`docs/decisions/rules-drop-stage.md`](../../docs/decisions/rules-drop-stage.md).** It is **not a `Route` case beside `.block`** and lives in the editor's **Advanced** section. It **obeys the master switch and group switches**, deliberately: "rules off" means Loom does nothing special, capture included, and a disabled group's capture rule must not drop either. **Which rules are live is `RulesState.applies`, and no matcher may spell that predicate itself** — master switch, group, per-rule flag and expiry are one function, asserted from the engine's side as well as the model's. **Dropping rather than filtering on read** is what makes the window and an agent's reads agree by construction. It affects **arrival of new ids only**: an in-flight exchange whose id is already in the store still completes (a drop rule added mid-request must not freeze a pending row), and `force` (replay, HAR import) records even when a rule would drop live traffic. `clearFlows` zeros the counters, because they are a session fact like `TunneledHostLog`. And it is **counted per rule** (`RulesState.droppedCounts`, `get_proxy_status.droppedByRules`, a strip under the request table), because a dropped exchange has no flow and therefore no `appliedRules` — that counter is the only place such a rule can be seen to have done anything, and an absence the operator caused is still an absence.

- **A refused handshake reaches three surfaces, and none of them is optional**: the console as `N refused`, an agent as `get_ssl_scope.tunneledHosts`, the request table as a `CONNECT` row carrying the error (`TunnelFlow.recordFailure`, called from `ClientTLSFailureReporter` and `HTTP2ConnectionErrorReporter`). It is **not gated on `observeTunnels`** — that flag is a volume decision about traffic that worked, and a request that never happened because Loom was in the path is something an embedder needs too. It is **one row per refused connection** (the per-host aggregate is `TunneledHostLog`; a row silently standing for 736 refusals is the worse of the two lies). And **transport teardown records nothing** — the h2 reporter's three tiers still decide — because a phone dropping an idle connection with RST is not a failed interception.

- **Nothing is pre-excluded and nothing is auto-excluded.** A guessed list is both incomplete (a corporate mirror is not on it) and quietly wrong (it hides traffic someone is looking for); auto-excluding a repeatedly-failing host would make this default silent again, for the reason in the record. The three writers of `exclude` are the card's picker, the row menu and `set_ssl_scope`.

- **`TunneledHostLog` is the aggregate, and the CONNECT rows are the per-connection view of the same fact** — neither replaces the other. Per `host:port`, bounded at 256, least-recently-active evicted, `evicted` counted so truncation is never silent, each with a `TunnelReason`: "one click from being captured" (`excluded` / `notInScope` / `interceptionDisabled`) and "no scope change will help" (`notTLSOrHTTP` for SSH/server-first, `noCertificateAuthority`, `leafMintFailed`) need different words, and `interceptable` carries that so no surface re-derives it. Recorded at **two** choke points only: `ProxyHandler.handleConnect` (which skips the sniff, so it must attribute for itself) and `TunnelSniffHandler.relay`; `ProxyHandler.passthroughReason` is the one shared attribution, and the scope's verdict deliberately outranks "no CA". Reads filter against the *current* scope (`TunneledHostLog.pending`), so a host someone just decrypted stops being offered while a `notTLSOrHTTP` one stays listed. **`clearFlows` resets it**, or the console goes on naming origins whose rows no longer exist anywhere.

- **An exclude is only for punching a hole in a glob, and the row menu prefers removal** (`SSLScope.stopIntercepting`, which `excludeHostTapped` goes through). Under a whitelist "stop decrypting this" is **dropping the include entry** — an un-named host is already relayed, so an exclude is redundant and worse: a standing carve-out that silently beats a later `intercept_host`. It goes in only when an include *glob* (`*`, `*.corp`) still covers the host, which removal cannot answer, and `StopInterceptOutcome` says which happened so the console reports the carve-out it just created rather than a bare success. A glob argument also drops the literal include entries that glob covers — matching them as hostnames never finds them. This is why `Passed through` is usually empty, and why the card renders it only when it holds something.

- **Decrypting a host also ends the tunnels already relaying it** (`RelayedTunnelRegistry`, closed from `ProxyEngine.interceptHost` **and** `setSSLScope`) — otherwise the write reaches only *new* connections while an HTTP client reuses the one it has. Four rules: registered at the **one splice** (`TunnelFlow.glue`, which is why it takes host/port); **only relayed** tunnels, since a decrypted connection is already being read; **only tunnels the resulting scope would decrypt**, because a host still shadowed by an exclude would reconnect straight back into a relayed tunnel (`interceptHost` reports the count as `closedTunnels`); and entries **remove themselves** off `closeFuture`, so the registry names live sockets rather than every socket ever spliced.

- **To the agent**: `get_ssl_scope.tunneledHosts` in one call (an agent that has to ask twice concludes "no requests" first) and `intercept_host`, which goes through `SSLScope.intercept(host:)` on one `InterceptionConfig.mutate` acquisition — the console and an agent are independent writers of the same scope, and a lost update means a host silently stops being decrypted. It reports `effective`, which is the point: an include entry **cannot** beat a wildcard `exclude`, so a write that lands while the traffic stays unread has to say so rather than look like success.

### What the capture path must record, and when

**A request is recorded when its head is parsed, not when it succeeds.** `CapturedExchange.observe` upserts the flow the moment `TLSInterceptHandler`/`ProxyHandler` has a request head; the exchange then continues *that* flow rather than opening a second one. It used to be created on the first body chunk (or on `.end`), so a request that arrived and then stalled — an h2 body blocked by flow control, an upload the client never finished, a header block the codec refused — recorded **nothing at all**, which on every surface is identical to a client that never ran. That is the same failure `TunneledHostLog` and `RefusalLog` exist to prevent, left open on the path that matters most. It was found the hard way: a phone uploaded 31 KB of HEADERS+DATA, got no response, and the capture was empty, so "Loom lost it" and "the app never asked" could not be told apart.

**And an error SwiftNIO raises is Loom's to answer.** A pipeline with no error handler turns a codec failure into an infinite wait — the operator blames their app and the capture agrees. Two were open: a client refusing Loom's leaf (now `.clientHandshakeFailed` in `TunneledHostLog`, with the handshake error in `detail`) and an intercepted HTTP/2 codec error (now `.protocolError`, and the connection is **closed**, because HPACK is per-connection state — RFC 7541 §2.3 — so nothing after an undecodable header block can be read either; RFC 9113 §5.4.1). Related: **a proxy must not be stricter than the origin** — `MITMPipeline.maxHeaderListSize` replaces SwiftNIO's 16 KB `SETTINGS_MAX_HEADER_LIST_SIZE`, which silently dropped every request from an app whose cookies had grown past it while the same header answered fine without Loom in the path. Details, the measurements and the upstream caveat about when the setting actually reaches the decoder: [`Engine/ProxyCore/CLAUDE.md`](CLAUDE.md).

WebSocket flows (ws:// and wss:// via MITM) are captured as a single flow whose frames appear in `get_flow_detail` under `webSocket.messages` (direction/kind/text-or-bytes) and are flagged in `get_recent_flows`. The three bugs behind that sentence — a `wss://` splice that wrote plaintext at a TLS server, a failed upgrade that recorded no flow at all, and a frame length that crashed the process from an event-loop thread — are in [`docs/decisions/websocket-capture.md`](../../docs/decisions/websocket-capture.md). Three rules survive them and apply to **anything parsing untrusted network bytes**, not just frames: lengths decode wide (`UInt64`) and narrow only once bounded; every remaining-bytes check is a **subtraction**, never an addition on a wire-supplied length; and "not enough bytes yet" and "these bytes aren't frames" are **different answers**, never both `nil`. A capture that stops is never silent — `Flow.webSocketCaptureError` reaches `get_flow_detail`'s `webSocket.captureStopped`, the summary's `captureTruncated`, and the Inspector's frame log.

GraphQL POSTs are recognized (`GraphQLParser`); `get_flow_detail` adds a `graphQL` block (kind/operationName/query/variables) and the Inspector shows a GraphQL tab. HTTP/2 is intercepted when the client negotiates ALPN `h2`: the MITM leaf advertises `h2`+`http/1.1`, and each h2 stream is demuxed through the h2↔h1 codec into the same `TLSInterceptHandler` capture path (falls back to http/1.1 otherwise). **Cleartext h2 (h2c, prior knowledge) is intercepted too** as of 0.0.27 — `ProtocolSniff` answers `.h2c` on the `PRI * HTTP/2.0` preface and `MITMPipeline.installCleartextHTTP2` gives it the *same* stack the ALPN branch uses.

Completed flows persist to `~/Library/Application Support/com.loom/flows.sqlite` (WAL + `synchronous=NORMAL`, row-capped, an order of magnitude larger than the in-memory ring) and reload on launch. Writes are **batched**: rows queue for a 50 ms window (or 256 rows) and land in one transaction through one reused prepared statement, and the row cap is enforced off a counter (`maxRows + pruneSlack`) instead of a full index scan per write; every read drains the pending batch first, so batching is invisible to callers, and `flush()`/`deinit` drain it so a quit can't lose it. Reads **read through** to it — **all** of them, as of 0.0.21: `FlowStore.flow(id:)` falls back to the row when a flow has aged out of the ring (so `get_flow_detail` / `diff_flows` / `replay_flow` still resolve an id an agent legitimately holds), `recentHydrated` (the HAR export path) tops up from disk, and `recent(matching:)` — the *filtered* read behind `get_recent_flows` / `get_stats` / `wait_for_flow` and the window's find bar — now falls through to `FlowPersistence.scan` once the ring is exhausted. That last one was the hole, and the asymmetry is what made it invisible: an agent could hold an id that resolved perfectly well and search for the same exchange to `[]`, because nine of every ten persisted flows sat past the ring. `[]` reads exactly like "that traffic never happened" — the `TunneledHostLog` failure one layer down. Three rules for that scan: only `host`(non-glob)/`method`/`status`/`since` are pushed into SQL and everything else re-runs in Swift on the decoded row (a `LIKE` approximating Loom's glob would drop matching rows silently); the ring is excluded **by id**, not by timestamp, because an in-flight exchange stays in memory while newer ones persist; and it is bounded (`FlowStore.historyScanRowBudget`, above the table's own cap) because it runs on the persistence queue that batched writes flush on — with `FlowSearchResult.budgetExhausted` reported when the bound bites, since a truncated search that looks exhaustive is the thing being fixed. `get_stats` carries that plus `flowsRetained`; `get_recent_flows` deliberately stays a bare array (an envelope on the most-used read, to carry a flag that can only fire above the row cap, is not a trade worth making).

## Performance — what the store pays for

Same framing as the window's half
([`Features/AppFeature/CLAUDE.md`](../../Features/AppFeature/CLAUDE.md#performance--what-the-window-pays-for)):
every one of these is a measurement, and several replaced an earlier version that was wrong.

- **A holder that persists off a lock enqueues the write under it.** `RulesConfig` / `InterceptionConfig` snapshot state under a lock and hand the write to a private serial queue *before* unlocking, so disk order matches mutation order; `flush()` drains it, and `ProxyEngine.flushFlows()` calls both on quit. Persisting after unlocking let two concurrent MCP writes land out of order and leave the file holding a stale snapshot — silently, until the next launch. Don't "simplify" it by persisting inside the lock either: `snapshot()` runs on the event loop for every request.

- **O(1) upsert.** The flow ring carries an `id -> absolute position` map (`FlowStore.positions`), so the several upserts every exchange performs (pending → completed, per streaming update, per WebSocket frame) are dictionary lookups, not scans of a 2000-element ring on the actor.

- **A read must not hold the write actor.** `FlowStore` is one actor and every capture write queues on it (twice per exchange, more for streaming, once per WebSocket frame), so any scan that runs *there* is a stall in front of all of them. `recent(matching:)` hands its work to an off-actor `scan` over a snapshot of the ring — free, because an `Array` of value types is COW. Measured on a full 2000-flow ring: an upsert costs 0.014 ms quiet and **1.8 ms** while such reads ran (127×); off the actor it is back to 0.015 ms. `FlowStoreScanContentionTests` pins it. Body hydration was already off-actor for the same reason.

  **And the way to not pay for a read is to not make it** — `ProxyEngine.proxyPort` exists because `status()` was the only way to ask the engine which port it is on, and answering that way costs four `FlowStore` hops plus a `RefusalLog` snapshot for one `Int` that is a stored property of the engine actor. Five callers wanted exactly that `Int`, one of them `applicationShouldTerminate` — reading the port to unset the system proxy while the capture path is still draining, holding AppKit on `.terminateLater` meanwhile. **A caller wanting to point something at Loom takes `proxyPort`; a caller rendering engine state takes `status()`.** The general form: an aggregate accessor is a convenience for whoever wants the aggregate, and a scalar it happens to contain is not a reason to build one.

  **And a count is a read**, which is the same rule one layer down and was live long after this entry read as settled. `FlowPersistence.storedRowCount` opened with `queue.sync { writePending() }`, so asking "how many flows are retained" forced a synchronous SQLite transaction of up to 256 rows — on the queue batched writes flush on, while holding the `FlowStore` actor — and it sat on the hot path through `ProxyEngine.status()`. It is mirrored out of the queue now (`approximateStoredRowCount`, pending batch included), so it costs a lock acquire; `RetainedCountContentionTests` pins it. The reusable half: a scan announces itself as expensive and a count does not, so the rule is about **entering the queue**, not about how much work is behind it. The call sites it reached, and how: [`docs/decisions/capture-path-performance.md`](../../docs/decisions/capture-path-performance.md).

- **A footprint figure is not a memory figure.** `phys_footprint` conflates what is handed out with what the allocator is sitting on, and the difference is large enough to send an investigation the wrong way: pushing 80 000 flows with 32 KB bodies through the store settles at ~400 MB of footprint against a flat **~100 MB in use** — allocator fragmentation from transient body buffers, plateauing, with nothing retained. Ask `malloc_zone_statistics` before concluding anything from a footprint delta, and measure each configuration in its **own process** (freed heap is not returned, so a second measurement reads the first one's cache as headroom — that artefact once made a store-less run look *cheaper* than a persisted one). The full record, including the one reduction available if it ever does hurt: [`docs/decisions/write-path-memory.md`](../../docs/decisions/write-path-memory.md).

- **Bound what's in memory.** Every in-memory collection has an explicit cap and the UI honestly surfaces when it dropped items (no silent truncation). **The three flow caps live in `FlowLimits`, not in default arguments** — `memoryRing` 2 000, `windowRows` 20 000, `persistedRows` 20 000 — because they were copied across five initialisers and half a dozen doc comments, and when the window's rose from 2 000 the copies that didn't move became wrong silently; `FlowLimitsTests` pins `memoryRing ≤ windowRows ≤ persistedRows`, which no single value can express (a window larger than the store is a row that draws and cannot be opened). The rest: audit = 1000 in the engine ring / 500 in the UI list, favicons = 512, per-host MITM TLS contexts = 512 LRU, app icons capped at 256 with hand-rolled eviction. The two icon caches were the exceptions until they weren't — `FaviconLoader.icons` stays a dictionary with hand-rolled eviction because `@Observable` can't track an `NSCache`, so a swap there would silently stop views refreshing.

- **Bodies out-of-line.** List/summary/boot reads stay body-free; a body is hydrated on demand only when a row is opened (see `FlowStore.hydrated` / SQLite BLOB columns). Never load megabyte bodies to render a list. The ring's own `bodyBudget` (64 MB) holds **regardless of capacity** — measured: 61 MB of live bodies whether the ring is 2000 or 20 000 flows, and whether the bodies are 32 KB or 256 KB. It also holds **without a store** as of 0.0.21, which it did not before: `enforceBodyBudget` opened with `guard persistence != nil` on the reasoning that dropping a body with nothing to hydrate from loses it, and the consequence was that an embedder (`persistFlows: false`) had no bound at all — 625 MB live for traffic that costs 61 MB with a store. Unbounded memory is not the safer side of that trade; the loss is answered by *recording* it (`Flow.bodiesEvicted` + `fullBodyBytes`, so a discarded body never reads as an absent one), not by declining to bound anything.

- **Aggregate incrementally, coalesce updates.** Sidebar counts (hosts / apps / devices / errors) are maintained as flows arrive, never recomputed by scanning a list on render, and the live flow stream is batched into one action per ~100 ms window (`CaptureFeature.streamFlows`) instead of one action per emission. **They are the engine's, over everything retained** (`FlowStore.flowAggregates()`, mirrored into the window on a coalesced re-read) — folding them in the window made every badge a count of the newest 2000 exchanges against a store keeping 20 000, so a busy host read as a quiet one and a host whose traffic had aged out vanished from the sidebar while its rows stayed on disk and searchable. Three rules keep the engine's version exact, each of which the obvious implementation gets wrong: a flow **leaving the ring has not left the capture** (it is on disk — only one that never completed, and so was never persisted, is a real removal); an **upsert re-counts** (a flow is folded at `.pending` and again at every state change, and its error-ness changes underneath); and **the pruner removes rows nobody upserted**, so `FlowPersistence` reports what it deleted (`onPrune`) or the counts drift upward forever. The window keeps exactly one per-flow projection of its own, `hostByRow` — a map keyed by flow rather than by host is the one that would scale with the capture, which is what the counters moved to the engine to stop doing.

  **And the boot fold counts columns, not decoded rows.** `FlowPersistence.aggregate()` runs once per launch over everything retained and used to decode the whole table — 20 000 rows, **383 ms, of which 3.6 ms is SQLite** — on the store's serial queue, in front of the batched capture writes. The four folded values are columns now (`appKey`/`appJSON`, `deviceKey`/`deviceJSON`, `isError`) and the same answer is a `GROUP BY`: **13 ms**. Two things that swap must not lose, both pinned by `FlowPersistenceAggregateTests`: a representative is grouped **by value** (`GROUP BY key, blob` — one row per distinct `SourceApp`/`SourceDevice`, not per flow), because `deviceReps` merges a device's typing across its flows; and **NULL must not read as "no app"** on a table written before the columns existed, which `PRAGMA user_version` gates — below it, `aggregate()` takes the old decode path *and* backfills, so exactly one launch after the upgrade pays what every launch used to. That launch measures ~51 ms rather than 13 and converges as rows are replaced ([`docs/decisions/capture-path-performance.md`](../../docs/decisions/capture-path-performance.md)), which is worth knowing before reading it as a regression.

- **A filter is prepared once, not per row.** `FlowQuery.matchesMetadata` did the query's own share of the work inside the loop — re-lowercasing the host pattern, an `NSString` bridge per `url_contains`, re-encoding the `header_contains` needle per flow. Per scan over a full 2 000-flow ring: `url_contains` **8.3 → 1.0 ms**, the three combined **9.8 → 4.3 ms**. `FlowQuery.metadataPredicate()` / `bodyPredicate()` hoist it and every scan site takes them (`FlowStore.scan`, `FlowStore.assemblePage`, `FlowPersistence.scan`); `matchesMetadata` remains as the one-shot spelling and is now *slower* per call, which is the honest trade and is said at the declaration. This is `FlowSearch.predicate()`'s rule applied on the side an **agent** pays for — `wait_for_flow` re-scans on every emission of the flow stream. Two things the fast path must not lose, both pinned: a literal host filter stays **case-insensitive** (`URLHost.hostMatches(urlString:lowercasedHost:)` folds as it compares — DNS is case-insensitive and nothing normalizes the URL a client sent), and the prepared and one-shot forms must agree flow-for-flow, or the answer depends on which internal path served it. The per-filter figures: [`docs/decisions/capture-path-performance.md`](../../docs/decisions/capture-path-performance.md).

- **A glob is matched over bytes, and the request it is matched against is derived once.** The same rule as above, on the path an exchange pays rather than a list read: `RuleEngine.matchingRules` and `BreakpointStore.firstMatch` both run the whole predicate list on the **event loop for every request**. Measured over 1 000 requests against 50 glob rules, **107 ms → 9.4 ms** — and the three costs behind that split, only one of which is the obvious one, are in [`docs/decisions/capture-path-performance.md`](../../docs/decisions/capture-path-performance.md) along with the prepared-rule-list design that was rejected for staleness. What must hold here: `Glob.Pattern`'s byte path is taken **only when the pattern and the string are both pure ASCII**, everything else falling back to the unchanged `String` implementation (`GlobTests` holds the two against each other — an IDN host in native script must not silently change which rules match); `Glob.pattern(for:)` is a bounded process-wide cache (`RegexCache`'s shape), so every caller with only a string gets it without plumbing; `RequestMatchContext`'s derivations are **lazy**, because deriving eagerly made the prefix and exact styles slower for a value they never read; the prepared pattern lives **on `RuleMatch` itself** (`preparedGlob`, rebuilt by `didSet` on the two inputs it derives from), so no second object can go stale against it; and `RuleMatch.matches(method:url:)` stays as the one-shot spelling while a caller matching **many** rules against one request takes a context. **A list walked per request is walked by index** — `for rule in rules` copies each rule, and a `RuleMatch` carries five refcounted fields, which was half the last win.
