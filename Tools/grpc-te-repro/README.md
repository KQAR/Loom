# `te: trailers` and gRPC (why Loom stops stripping it on an HTTP/2 leg)

`TE` is a hop-by-hop field (RFC 9110 §7.6.1), so a proxy removes it. **RFC 9113
§8.2.2 carves it out by name for HTTP/2** — a request may carry `te` when the value
is exactly `trailers` — and the gRPC wire spec makes it mandatory.

Loom stripped it on both legs. This probe measures what that costs, with a raw
HTTP/2 framer client so the *only* difference between the two calls is that one field.

## Running it

```
go run .                       # against a grpc-go server it starts itself
python3 ccore_server.py &      # needs: pip install grpcio grpcio-health-checking
go run . 127.0.0.1:<port>      # against a grpc C-core server
```

## What it shows

`grpc-go` v1.83.2 — **does not check**:

```
with    te: trailers   :status=200 grpc-status=0   => the RPC succeeded
without te: trailers   :status=200 grpc-status=0   => the RPC succeeded
```

grpc **C-core** (grpcio 1.84 — the transport behind C++, Python, Ruby, C#, PHP and
Objective-C) — **rejects**:

```
with    te: trailers   :status=200 grpc-status=0   => the RPC succeeded
without te: trailers   RST_STREAM INTERNAL_ERROR   => the RPC did NOT succeed
```

No status, no message, nothing for the operator to read. Its source says why —
`src/core/ext/filters/http/server/http_server_filter.cc`:

```cpp
auto te = md.Take(TeMetadata());
if (te == TeMetadata::kTrailers) {
  // Do nothing, ok.
} else if (!te.has_value()) {
  return MalformedRequest("Missing :te header");
```

`grpc-java` sits between the two: it serves the request and logs
*"Expected header TE: trailers, but null is received. This means some intermediate
proxy may not support trailers"* (`NettyServerHandler`) — which is Loom.

**One implementation was not enough to answer this.** Checking grpc-go alone says
"no problem"; checking C-core alone says "always broken". The truth is that it
depends on the server, which is exactly why the field has to be forwarded.
