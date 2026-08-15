# Reading a red CI run on `main`

> Moved out of `AGENTS.md` on 2026-08-07 (0.0.18), unedited. It is a **record**, not
> an instruction: what was tried, what it cost, and why the current shape is the
> shape. The invariant it produced lives in [`AGENTS.md` § CI](../../AGENTS.md#ci), which links
> here — read that first; come here when you are about to re-open the question.

**A red run on `main` is not automatically a regression.** Re-run the failed job before diagnosing. The breakpoint-timing flakes are now **fixed rather than tuned**: `BreakpointTests` waits on the `pendingStream()` announcement instead of spinning `Task.yield()`, proves watchdog cancellation by awaiting the watchdog and checking `BreakpointStore.timeoutResolutions` instead of sleeping past its deadline, and carries a suite-level `.timeLimit` so a genuine stall fails by name instead of hanging the run. If one of those goes red now, treat it as real — and it happened: `resolvingAHold_cancelsTheTimeoutWatchdog` went red under TSan (only there, and only on the `main` run) because `hold` announced a parked exchange *before* arming its watchdog, so "announced" did not imply "fully parked". TSan slows the tail of `hold` enough to lose that race. `hold` now arms and attaches the watchdog before announcing (and skips the announcement entirely if the hold was already resolved, which would hand a waiter something it can't act on), and `anAnnouncedHold_alreadyHasItsWatchdogArmed` pins the ordering through the `willAnnounceParked` seam rather than by reading state after an announcement — that reading passes under either ordering on a fast machine, which is exactly how the bug shipped. Removing the DerivedData cache exposed a second family of the same kind — tests that drove a real client and then read `recentFlows()` on the next line, which is a race because capture finishes on the event loop *after* the last byte reaches the client. It only ever passed because the runner was fast and idle; `interceptsTLSOverSOCKS` was the first to lose it (flow found, `response.body` still nil). Fixed rather than tuned, again: `awaitFlow` / `awaitFlowBlocking` in `EngineTeardown.swift` wait, bounded, for a flow that satisfies a condition, and every such site now uses one of them — so a genuine capture regression still fails by name instead of becoming a sleep that rots. What is still genuinely flaky: `HTTP2InterceptionTests` (see the h2 note below) and infrastructure — a job the hosted runner never picks up fails with "not acquired by Runner", which is not your change. **A `cancelled` job is a third thing again, and it does not mean anyone cancelled anything.** `timeout-minutes` covers "Set up job", so a job whose budget expires while GitHub is still resolving its `uses:` actions is killed there and reports *cancelled* — during an Actions outage the setup log reads `Failed to resolve action download info. Error: Service Unavailable`, three re-runs in a row die identically, and the downstream jobs then report *skipped* because their `if:` depended on a job that never produced its output (which reads, wrongly, as "CI decided my change was docs-only"). The tell is the step list: no completed step other than "Set up job" means GitHub, not this repo — `gh api repos/KQAR/Loom/actions/jobs/<id> --jq '.steps'` — and https://www.githubstatus.com settles it in one call, because re-running is wasted until Actions is `operational` again. `changes` now carries a job budget wide enough to sit through GitHub's own retries plus a two-minute budget on the step that does the work, so a genuine stall in the `git diff` fails by name instead of wearing the same word as an outage. Note this is **not** the documented h2 flake below: that one is the *upload* test and prints byte counters. Also note the PR check and the `main` check are separate runs, so a green PR does not mean `main` went green — look at both before tagging a release.

---

## Later note (0.0.27): `h2RequestIsDecryptedForwardedAndCaptured()` had two causes, and one is still unknown

The suite-limit timeout on that test is **still open, with one cause removed**. One was the
test blocking a cooperative-pool thread; that is fixed and has a deterministic reproduction
(`EngineTeardown.swift` § "Why there is no `runBlocking` here any more", with
`TEST_RUNNER_LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`).

The timeout **outlived it**: a re-run of the very commit that fixed it went red, and the next
went green. So do not read the fix as closing this — a second cause is still unknown.

What changed is that the test now *reports*. A bounded 25 s per-stage deadline under the
suite's 60 s fails with the stage, the timeline, the negotiated ALPN (an `http/1.1` leaf
against an h2 client hangs identically and means something else entirely) and a stack sample.
That is what makes the next red run worth reading rather than re-running, and it is how this
gets closed.
