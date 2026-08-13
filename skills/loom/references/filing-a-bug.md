# Filing a Loom bug (public issue — scrub before you post)

## First, check it's actually a Loom bug

These are known and documented; refiling them is noise:

| What you see | What it is |
|---|---|
| An h2 upload > 65535 bytes hangs, ~1 in 100 | Upstream NIOHTTP2 defect, already tracked as #99 — decided to live with it |
| Apple / pinned domains fail under HTTPS interception | Certificate pinning working as designed, not a bug |
| HTTPS captured but bodies empty | CA not trusted on the client, or host out of SSL scope — check `get_certificate_status` / `get_ssl_scope` |
| `get_version` reports a version you just replaced | The app was rebuilt but not relaunched |
| Nothing captured at all | Nothing is routed through the proxy — check `get_proxy_status.systemProxy` (`other` = another proxy app owns the setting) |
| A flow's `request.httpVersion` is `HTTP/2` and `response.httpVersion` is `HTTP/1.1` | Two different facts: the client's leg and Loom's own hop to the origin, which is always HTTP/1.1 |
| `transport.setup` / `upstreamTLS` / `connectionReused` missing on a flow | Unmeasured, not zero — a reused connection paid no setup, a mocked or blocked exchange never reached a socket |

## Then scrub

By the time you decide to file, your context is full of the user's real traffic —
and the instinct that makes a *good* bug report (paste the exact failing request)
is exactly the wrong one here. A GitHub issue is public, indexed, and effectively
permanent; a deleted issue was still readable.

**Never put these in an issue**, in prose, in a code block, or in an attachment:

- Real hostnames or domains — including the user's employer, client, product,
  project, or internal service names, and anything recognisable in a bundle id
- URL paths and query strings that carry identifiers (order / account / user /
  session / trace ids)
- Request or response bodies, verbatim or excerpted
- `Authorization`, `Cookie`, `Set-Cookie`, API keys, JWTs, signatures — redacted
  or not, don't include the value or its shape
- Emails, phone numbers, names, device names, LAN IPs, `/Users/<name>/…` paths
- **A HAR file.** `export_har(redact: true)` scrubs credential headers and token
  query params — and nothing else: bodies and WebSocket frames come through
  verbatim unless you also pass `redact_bodies: true`. Even with both, hostnames,
  paths and timings survive, and that is business data. Keep it local; offer it to
  the maintainer privately only if they ask.

**Use placeholders consistently** so the report still reads: `api.example.com`,
`https://api.example.com/v1/items/{id}`, `<redacted-token>`, `AppUnderTest`,
`/Users/<user>/…`. Replace the *same* real value with the *same* placeholder.

**Reproduce on a neutral endpoint before filing.** If the failure survives against
`httpbin.org` / `example.com` / a throwaway local server, the report needs none of
the user's traffic and the maintainer can act on it immediately. If it genuinely
only reproduces against the real host, describe the *shape* — method, status,
approximate body size, content type, h1 vs h2, chunked vs fixed-length, TLS on/off
— never the identity.

**Keep what is actually diagnostic:** Loom version (`get_version`), macOS version,
proxy status, whether HTTPS interception was on (say "3 hosts in scope", not which
hosts), rules/breakpoints armed at the time (kind of rule, not the URLs), the exact
error text Loom itself emitted, and relevant lines from
`log stream --predicate 'subsystem == "com.loom"'` — scrubbed the same way.

## Then publish, with approval

**Show the human the full rendered issue and get explicit approval before creating
it.** Publishing is outward-facing and hard to take back; the user is the only one
who knows whether a name is sensitive. Then:

```bash
gh issue create --repo KQAR/Loom --title "…" --body "…" --label bug
```

Say plainly what you redacted ("host names replaced with `api.example.com`, body
omitted") so the maintainer knows the gaps are deliberate and can ask for more
through a private channel.
