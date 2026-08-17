# The SSL scope is a whitelist, and what it cost to make the unread run visible

> Moved out of `AGENTS.md` on 2026-08-15, unedited but for the linking sentences. It is a
> **record**, not an instruction: what was tried, what it cost, and why the current shape is
> the shape. The invariants it produced live in [`AGENTS.md` § Known Issues](../../AGENTS.md#known-issues), which links here —
> read that first; come here when you are about to re-open the question.

The entry that sent you here was 18 KB, a third of [§ Known Issues](../../AGENTS.md#known-issues), and most of it was this:
five rejected surfaces, three tool comparisons and the measurements that settled them.

## Why a whitelist at all

`toggleSSLTapped` seeds nothing: `include` starts empty and nothing is decrypted until a host
is named. The wide default it replaces (`include: ["*"]`) made Loom terminate TLS for every
client on the machine, a phone's whole OS included — a measured session had **67 origins
refusing Loom's leaf**. 0.0.27 briefly shipped that wide default as a reversal and then kept
the whitelist; what is worth keeping is why the unread first run must not be silent.

Charles (empty include list since 3.4) and Proxyman (SSL Proxying List, wildcard opt-in) both
land on the whitelist for the same reason. The wide default's failure mode is loud (a refused
handshake in the operator's own client) and repairable (one `exclude`); the whitelist's is
silent unless every unread origin is a CONNECT row. mitmproxy keeps the wide default and eats
the noise.

So the direction is **name it, then decrypt** — which puts the whole weight on the unread
origin being visible, and that is what everything below is about.

## The gap that made the CONNECT row necessary

`TunnelFlow.recordFailure` (called from `ClientTLSFailureReporter` and
`HTTP2ConnectionErrorReporter`) was missing for a release, and the gap is instructive:
`observeTunnels` records the connections Loom *relayed*, so an operator saw rows for the hosts
they had already fixed and nothing for the one that was breaking.

Three costs of the per-connection choice, all accepted rather than hidden: a chatty origin
contributes a row per connection (a measured hour of one phone: 186 to `gateway.icloud.com`);
these are **real flows** — they persist, they count in `capturedCount`, they reach
`get_recent_flows`; and they spend the same `FlowLimits.persistedRows` budget as content
exchanges, so a session dominated by pass-throughs retains less real history. The tool
description says a `CONNECT` entry is a connection and not an exchange, because an agent asking
"what did the app call" now sees them.

Adding the SSL column also cost Path 40pt of floor: every column carries ~17.5pt of `.inset`
padding and intercell spacing beyond its width, so a 9-column table at a 700pt viewport sat
40pt over even with Host and Path on their minimums — that was with the column headed
"Decrypted" at 72pt; at 36pt (and Host's floor up to 140) the same nine floors come to ~701pt,
which is the overflow horizontal scrolling is for. `noWidthLeavesDeadSpaceAtTheRight` now
separates dead space (never allowed) from overflow (what horizontal scrolling is for), which
the old `abs(gap)` assertion conflated.

Failed and not-attempted were drawn alike at first, and that is the more misleading direction:
a pass-through is the configuration working, a refusal is a request that never happened.

## The aggregate that was built, deleted, and kept in two other places

A **sidebar panel** was built for this first and deleted: aggregating per host is what
Charles's *Structure* view does, and Charles's flat Sequence list is per-connection like this
one — Loom has only the flat list, so the aggregate lives in the console card and
`get_ssl_scope.tunneledHosts` instead.

`clearFlows` resetting `TunneledHostLog` was not the first behaviour: the log is in-memory and
survived a clear, so the console went on naming origins — with `connections` counts and an
orange icon — whose rows no longer existed anywhere. Measured in use as "I removed this host
and it vanished from the request list": the row had been cleared, the entry had not, and the
two readings could not both be right. Clearing is "forget what this session saw", and every
surface answering from the session has to hear it.

`SSLScopeCard` used to lead with the seen-not-decrypted list; that list is gone from the
console, because the request table answers the same question one `CONNECT` row at a time *with
the action attached*, and keeping both made this a second aggregated rendering of the same
origins — a 256-host log showing 6 at a time, in a 300pt panel, above the two lines someone
opened the card to edit. One surface per question: the table lists origins, the card holds the
configuration. A **refused** origin is diagnosed and repaired on its request-table row (or by
the agent), not repeated in the console summary. Deleted with it:
`tunneledHostsByUrgency`/`urgencyRank`, which existed
only to order that list. The disclosure `Passed through` used to sit behind was one line naming
a count of a list nobody could see, on a card whose whole job is to show the two lists.

## The refused-origin bug the projections hid

Measured on a real Android device: `mcp.fintopia.tech` refused Loom's leaf, the phone showed a
network error, and the only trace anywhere was `get_ssl_scope`. `TunnelReason` had split the
two kinds from the start — `TunneledHost.brokeTheClient` (`clientHandshakeFailed` /
`protocolError`) means the request *never happened*, as against an unread relay that reached
its origin — and then nothing called it. Two reasons at once: a broken origin is
`interceptable == false`, so `unexpectedlyUnreadHosts` excluded it and **neither the count nor
the orange tint fired** (the row read "all hosts" while one host had refused 736 handshakes);
and `SSLScopeCard` sorted `!interceptable` last, so the row lost the card's 6 visible slots to
a 256-host log. `SSLScopeCard.offersExclude` was offered only for `interceptable` rows, i.e.
never where it fixes something, leaving a warning with no action beside it.

## Later correction: one success is recovery, not erasure

An OPPO WebView produced 76 certificate-rejected CONNECTs and then completed TLS to the same
origin after its recoverable SSL-error path ran. Loom stored every failed row but deleted the
host aggregate on the first successful handshake, so `get_ssl_scope` denied evidence the flow
store still held. The replacement keeps failure/success counts and timestamps: failures only
are `stillFailing`, both outcomes are `mixed`, and `latestResult` says which happened last
without claiming every client recovered. It also separates connection diagnostics from HTTP
exchange statistics — one successful h2 connection can carry dozens of requests, so mixing
those grains cannot produce either a request failure rate or a connection failure rate.

Charles keeps CONNECT in its Sequence View and adds Structure/filtering; Proxyman likewise
surfaces handshake failures in traffic rather than hiding them in a log. Loom follows that
evidence rule: `All Flows` remains the raw sequence, while Requests / Connections are explicit,
composable filters with retained-history counts and the same underlying rows.

## The four surfaces that were rejected

The noise is irreducible under the wide default — one phone contributes dozens of origins
(Apple, MIUI, heytap, Google) that will never trust Loom's CA and retry forever, so anything
persistent enough to be noticed is also persistent enough to be ignored, which is the lesson
`unexpectedlyUnreadHosts` already encodes.

- A **banner** was built and reverted for exactly that (67 of 67 entries broken in the measured
  session, 5 slots).
- A **sidebar row** is the same push in a cheaper frame.
- An **acknowledge/dismiss state** is a patch on a problem the banner created, and needs its
  own persistence because `TunneledHostLog` is in-memory.
- **Auto-excluding a repeatedly-failing host is the worst of them**, however much it looks like
  the obvious fix: `SSLV3_ALERT_CERTIFICATE_UNKNOWN` is what a pinned client *and* a client
  with no trust anchor both send, so on a machine where the CA isn't installed yet it would
  walk the whole capture into `exclude` and leave it there after the human fixed trust —
  reintroducing this very defect with the cause buried in history. mitmproxy is the reference
  for this default and does none of it: one log line per failure naming the host and the reason
  (`Client TLS handshake failed. The client may not trust the proxy's certificate for <host>`),
  and its `tls_passthrough.py` auto-exclusion lives in `examples/contrib/`, unmaintained
  (mitmproxy#4567). Report it, let the operator decide.

Listing the CONNECTs instead is the wrong shape and stays rejected: `observeTunnels` already
does it and is off by design (a browser or a pooling client opens tunnels it may never speak
on, and a row with no method, status or body cannot be opened). What is worth surfacing is the
verdict, one line per origin — which is what `TunneledHost` already is.

## The row menu's two gates, both bugs first

**The exchange must be TLS** (on a plain `http://` row the scope decides nothing) and **the
scope decides the direction**, never the row — scheme alone offered Pass Through on replayed
flows, HAR imports and reverse-proxy flows, whose recorded URL is the upstream `https://` one,
so the write changed nothing while the console reported a fresh success.

The wildcard widens by **exactly one label** (`parentWildcard`), because reaching the
registrable domain needs a public-suffix list and the "last two labels" guess answers `*.co.uk`
for `shop.example.co.uk`; hosts with fewer than three labels and IPv4 addresses get no item at
all, and the residual case is answered by the menu item spelling the glob out before it is
clicked.

## Why decrypting has to close the tunnels already relaying the host

Without `RelayedTunnelRegistry` the write reaches only *new* connections while an HTTP client
reuses the one it has — measured on a real app: seven requests over two connections, and a home
screen refreshed repeatedly on a connection opened minutes earlier, so the operator clicks
Decrypt and watches nothing happen with the setting already correct. A relayed tunnel is a byte
splice, so nothing inside it can ever be read; the only repair is a new connection, and Loom
holds one end of the socket. It uses the client's own reconnect path rather than working around
it. The cost is stated rather than hidden — a request in flight is retried by the client or
fails — and it is acceptable because it lands in the second after someone asked to decrypt that
host, which is attributable in a way a drop at a random later moment is not.
