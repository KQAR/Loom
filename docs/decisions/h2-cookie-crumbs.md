# The cookie crumb split is an encoding, not a field

> Moved out of `AGENTS.md` on 2026-08-15, unedited but for the linking sentences. It is a
> **record**, not an instruction: what was tried, what it cost, and why the current shape is
> the shape. The invariant it produced lives in `AGENTS.md` § Known Issues, which links here —
> read that first; come here when you are about to re-open the question.

## The bug that started it (0.0.24)

RFC 9113 §8.2.3 lets an h2 client split `cookie` into one field per cookie (Chrome does), and
requires an intermediary converting to h1 to concatenate them with `"; "`.
`HTTP2FramePayloadToHTTP1ServerCodec` does **not** — NIOHTTP2 has no `cookie` handling at all —
so the intercepted request left Loom carrying N `Cookie:` lines, and RFC 6265 §5.4 allows
exactly one, so origins read the first crumb and dropped the rest.

The failure is silent and looks nothing like a proxy bug: **a signed-in site comes back signed
out** (github.com's `user_session` crumb wasn't first) and signing in again fails 422, while
the browser still holds every cookie — so it reads as "Loom broke my login".

## Why the merged field stayed canonical when a second leg appeared (0.0.27)

§8.2.3 requires the concatenation before the fields reach "an HTTP/1.1 connection, **or a
generic HTTP server application**" — so the origin's application sees one field however the
request was framed, and the crumb split sits below the semantic layer, like a body's DATA-frame
boundaries or a TLS record edge, none of which Loom records either.

Keeping crumbs in the model instead was considered and rejected: `get_flow_detail` would report
three `cookie` fields for one logical request, `diff_flows` would call an h2 capture and an h1
capture of the same request different, and the `"; "` rule would have to be re-learned by rule
matching, breakpoint edits, replay, curl export and HAR export — one definition turned into
six.

What the split costs on the wire, stated rather than hidden: HPACK is the win a client gets
from crumbs (a merged kilobyte of cookie cannot fit the 4096-byte dynamic table, so it is
re-sent as a literal every request), which is why `HTTPUtil.splitCookieCrumbs` re-splits on the
way out over h2. The h1 leg's single-line length limit — nginx's `large_client_header_buffers`,
8 KB — is **not** fixed by any of this and cannot be, since RFC 6265 §5.4 allows exactly one
field there.
