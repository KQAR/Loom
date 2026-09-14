# The un-sendable HEADERS frame (swift-nio-http2)

`swift run` here stands up an h2c server and an h2c client, both swift-nio-http2, and
sends one request whose only unusual property is the size of a header value. It
**uses no Loom code** — the point is that the failure is upstream of Loom, in the
client's own frame encoder.

## What happens

`HTTP2FrameEncoder.encode` puts an entire HPACK block into one HEADERS payload and
then checks it against `SETTINGS_MAX_FRAME_SIZE`:

```swift
// Confirm we're not about to violate SETTINGS_MAX_FRAME_SIZE.
guard payloadSize <= Int(self.maxFrameSize) else {
    throw InternalError.codecError(code: .frameSizeError)
}
```

There is no CONTINUATION path on the write side (RFC 9113 §6.10 — NIOHTTP2 only
*parses* them, with `maximumSequentialContinuationFrames` bounding the read).
`HTTP2ChannelHandler` turns that `codecError` into
`NIOHTTP2Errors.UnableToSerializeFrame` and fires it as a **connection** error, so
every other stream on the socket dies with it.

`maxFrameSize` is the peer's advertised value, whose initial — and minimum
permitted — value is 16 KB (RFC 9113 §6.5.2). So roughly 16 KB of request fields is
the ceiling, and a real HTTP/2 client is not subject to it, because a real client
sends CONTINUATION.

Measured on **1.44.0** (the pin), base64-alphabet values so Huffman coding cannot
shrink them the way a run of one character would:

```
1024 byte header value:      client: write accepted
7168 byte header value:      client: write accepted
12288 byte header value:     client: write accepted
20480 byte header value:     client: REFUSED — UnableToSerializeFrame
30720 byte header value:     client: REFUSED — UnableToSerializeFrame
```

The **response** direction is the same encoder, and `swift run h2-frame-size -- --response`
drives it — an h2 server answering an h2 client:

```
16000 byte response header value:
    client: got :status 200
30720 byte response header value:
    server: REFUSED — UnableToSerializeFrame
    client: NO RESPONSE — the stream was never answered
```

That last line is the whole point: the client gets no status, no reason and no
bytes, and every other stream on the connection dies with it. It is the silent
hang, not a visible error.

## Why Loom cares

Loom re-encodes every intercepted request onto its upstream leg, and since 0.0.27
that leg matches the client's protocol — so an app sending a large field section
(an attestation token, a grown cookie jar, or both) had its request refused **only
while Loom was in the path**. Direct, and through a plain tunnelling proxy, the same
request is answered 200.

There is no knob to fix and no way to pre-split. `HTTP2HeaderBudget` holds the one
ceiling; each leg answers it with what it has. Upstream, the lever is which protocol
the leg speaks — an oversized section goes out over HTTP/1.1, which has no frame, and
the flow is marked `FlowTransport.upstreamProtocolDowngraded`. On the client leg there
is no lever, because the connection already exists: `StreamRelay` answers 502 with the
reason and keeps the origin's real head on the flow.

This is the encoding-side twin of `Tools/h2-hpack-repro`, which is about the same
library refusing header blocks on the way *in*.
