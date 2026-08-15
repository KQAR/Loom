# The capture write path's memory: measured, and not a leak

> Moved out of `AGENTS.md` on 2026-08-15, unedited but for the linking sentences. It is a
> **record**, not an instruction: what was tried, what it cost, and why the current shape is
> the shape. The invariant it produced lives in [`AGENTS.md` § Conventions](../../AGENTS.md#conventions), which links here —
> read that first; come here when you are about to re-open the question.

*Investigated 0.0.21. Numbers are Debug, arm64, and each figure below is from a probe
that was deleted after reading — reproduce by re-writing it rather than trusting the
numbers to still hold.*

## Why this was opened

While measuring the ring's body budget (`docs`-adjacent work in PR #279), a footprint
figure kept showing up that nothing accounted for: pushing 20 000 flows with 32 KB
bodies through a persisted store left **~330 MB** of phys_footprint behind, while the
ring's live bodies were pinned at 61 MB by its budget and its metadata was ~26 MB. Some
250 MB was unexplained, and `malloc_zone_pressure_relief` returned none of it — which
rules out "the allocator is merely caching", or so it seemed.

It was also, at that point, easy to assume the batched write queue was accumulating.

## What it actually is

Asking the allocator directly (`malloc_zone_statistics`) rather than the kernel
separates the two questions the footprint conflates — *handed out* versus *mapped*:

| after 20 000 flows × 32 KB | value |
|---|---|
| malloc **in use** | 93 MB |
| malloc **allocated** | 192 MB |
| phys_footprint | 125 MB |
| peak rows waiting in the write batch | **209** (cap is 256) |

93 MB in use is the live data: ~61 MB of ring bodies plus metadata plus overhead. So
nothing is held that shouldn't be, and the write queue is bounded exactly as designed —
the batching cap does its job, and the "pending is accumulating" theory is dead.

Repeating the burst four times (80 000 flows in total) settles the rest:

| | in use | allocated | footprint |
|---|---|---|---|
| burst 1 | 93 MB | 192 MB | 125 MB |
| burst 2 | 103 MB | 868 MB | 591 MB |
| burst 3 | 103 MB | 1360 MB | 396 MB |
| burst 4 | 103 MB | 1360 MB | 399 MB |

**In use is flat.** Allocated and footprint rise and then plateau. That is the signature
of allocator fragmentation — 20 000 transient 32 KB body buffers per burst, churned
through a zone that keeps a free pool rather than returning pages — not of anything
retaining data.

## What it is not

- **Not the WAL.** It stays between 0 and 8 MB across every burst; SQLite is
  checkpointing normally.
- **Not unbounded disk.** The file plateaus at 659 MB, which is the 20 000-row cap
  holding at 32 KB a row.
- **Not the pending batch.** Peak 209 rows against a 256 cap.
- **Not reclaimable by asking.** `malloc_zone_pressure_relief` moves none of it, which
  is why the first look mistook it for live memory.

## Decision: no fix

The workload above is a deliberate worst case — every exchange carrying a 32 KB body,
80 000 of them back to back at machine speed, with no pauses for the allocator to settle.
Real capture is far lighter and far spikier. Against that, the shape is: bounded live
memory, a plateau rather than a climb, and no data retained past its lifetime.

A real reduction is available if this ever *does* hurt, and is written down here so it
does not have to be re-derived: `FlowPersistence.bindBlob` binds bodies with SQLite's
`transient` destructor, which makes SQLite copy every body into its own memory — a second
32 KB allocation per flow. Binding `static` instead would avoid the copy, at the cost of
keeping each `Data` alive across `sqlite3_step` (so the bind and the step must nest
inside `withUnsafeBytes`, for three columns). That is a correctness-sensitive change to
the write path in exchange for a workload that is not currently suffering, which is the
wrong trade today and might not be later.
