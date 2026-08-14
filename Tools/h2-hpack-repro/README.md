# The pre-ACK HPACK limit (swift-nio-http2)

`repro.py` shows an HTTP/2 server built on swift-nio-http2 refusing a header block it
advertised itself as willing to accept. It is 60 lines of Python, hand-encodes HPACK
literals, and **uses no Loom code** — the point is that the defect is upstream.

## What happens

`HTTP2FrameParser` builds its decoder as `HPACKDecoder(allocator: allocator)`, i.e.
with the library default `maxHeaderListSize` of 16 KB, whatever `initialSettings`
says. That value is only raised in `localSettingsChanged`, which fires when the peer
**ACKs** the server's SETTINGS. RFC 9113 §3.4 explicitly permits a client to send its
first request without waiting for that ACK, and OkHttp does.

So a first request whose *decoded* header list exceeds 16 KB is refused with
`NIOHPACKErrors.MaxHeaderListSizeViolation`, which becomes a connection-level
`COMPRESSION_ERROR`. HPACK is per-connection state, so the connection cannot continue.

Still present in **1.45.0**, and `NIOHTTP2Handler.Configuration` exposes no knob for
the decoder.

## Running it

Point it at a proxy that MITMs `example.com` (`PROXY`/`HOST` at the top), or adapt the
`CONNECT` preamble away for a direct h2 server.

```
python3 repro.py 200 60     # ~20 600-byte header list, sent immediately
  <- GOAWAY len=8  errorCode=0x9

python3 repro.py 20 60      # ~2 240 bytes, sent immediately
  <- HEADERS len=121
```

Sending the same 20 600-byte list *after* ACKing the server's SETTINGS is answered
normally — that is the whole shape of the bug.

## Why it matters to a proxy

The header block belongs to the *client*: a debugging proxy cannot make an app's
cookies smaller, and an app whose session cookies have grown to 15–31 KB is ordinary.
Loom's workaround is to stop offering ALPN `h2` to such a host, which keeps the traffic
readable at the cost of the client leg no longer being the protocol the app would have
chosen (`HTTP2DowngradeRegistry`, `FlowTransport.clientProtocolDowngraded`). The real
fix is one line upstream: initialize the decoder from `initialSettings`.
