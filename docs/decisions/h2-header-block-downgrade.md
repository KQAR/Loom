# The pre-ACK HPACK limit, and why Loom answers it by dropping ALPN `h2`

> Moved out of `AGENTS.md` on 2026-08-15, unedited but for the linking sentences. It is a
> **record**, not an instruction: what was tried, what it cost, and why the current shape is
> the shape. The invariant it produced lives in [`AGENTS.md` § Known Issues](../../AGENTS.md#known-issues), which links here —
> read that first; come here when you are about to re-open the question.

## The upstream defect (nio-http2 1.45.0, unfixed)

SwiftNIO builds its HPACK decoder as `HPACKDecoder(allocator:)` with the library's 16 KB
`maxHeaderListSize`, **whatever `initialSettings` advertises**, and raises it only in
`localSettingsChanged` — i.e. when the peer ACKs. RFC 9113 §3.4 lets a client send its first
request before that, and OkHttp does, so a first request whose *decoded* header list exceeds
16 KB is refused with `MaxHeaderListSizeViolation` → connection-level `COMPRESSION_ERROR` →
dead connection.

This is the sibling of the `MITMPipeline.maxHeaderListSize` entry and is **not** fixed by it:
that one raised the frame-length preflight, and a 20 600-byte list compresses to a 14 661-byte
frame, which sails through.

Measured on a real Android app whose cookies had grown. `Tools/h2-hpack-repro` reproduces it in
60 lines with no Loom code, and the same 22 KB `Cookie` over HTTP/1.1 through Loom answers 200.
`NIOHTTP2Handler.Configuration` exposes no knob — the fix is one line upstream.

## Why the trigger is what it is

The GOAWAY code is how NIOHTTP2 reports a `MaxHeaderListSizeViolation` after wrapping it as
`unableToParseFrame()`; the typed error (`NIOHTTP2Errors.ExcessivelyLargeHeaderBlock`) is what
the decoder raises before that wrap, and requiring the code alone **missed it**. A frame-size
or protocol violation, by contrast, is the client's own bug, and hiding it behind a protocol
change would misattribute it.

## Why the mark is not optional

`CapturedRequest.httpVersion` reads `HTTP/1.1` after a downgrade, which is true of what
happened and **false about what the app would have done** — and an operator comparing a capture
with production is measuring exactly that difference. Hence
`FlowTransport.clientProtocolDowngraded`, rendered for the agent and drawn in the Inspector in
the warning colour.

The alternative to the whole mechanism was a connection that dies with no explanation, so the
trade is worth taking; what it must never be is invisible.
