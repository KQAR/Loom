import Foundation
import LoomSharedModels

/// How a held exchange should continue, delivered by `resumeBreakpoint`.
enum BreakpointResolution: Sendable {
    /// Apply the edit (possibly empty = unchanged) and continue.
    case proceed(BreakpointEdit)
    /// Fail the exchange with a synthesized 502.
    case abort
}

/// Thread-safe holder for armed breakpoints and currently-held exchanges, shared
/// between the actor (which arms/lists/resumes) and the forwarding path (which
/// parks a matching exchange on a continuation and awaits a decision). Kept off
/// the actor — like `RulesConfig` — so forwarding never has to hop to the actor
/// just to check for a breakpoint. Not persisted: a held exchange holds a live
/// connection open, so it can't survive the process.
final class BreakpointStore: @unchecked Sendable {
    private let lock = NSLock()
    private var breakpoints: [Breakpoint] = []
    private var held: [UUID: Held] = [:]

    /// A parked exchange plus the continuation that releases its `await`, and the
    /// timeout task watching it — cancelled the moment anything else resolves the
    /// hold, so a resumed exchange doesn't leave a task sleeping for the full
    /// timeout.
    private struct Held {
        var info: PendingBreakpoint
        var continuation: CheckedContinuation<BreakpointResolution, Never>
        var timeout: Task<Void, Never>?
    }

    /// Holds whose task was cancelled *before* `hold` managed to park them. The
    /// cancellation handler can run concurrently with the body, so it records the
    /// id here and the body aborts instead of parking — otherwise a cancel that
    /// lands in that window would be lost and the exchange would wait out the
    /// whole timeout with nobody listening.
    private var cancelledBeforePark: Set<UUID> = []

    /// How long a held exchange waits before auto-proceeding unchanged, so a client
    /// connection can't hang forever if no operator ever resumes it.
    private let timeout: TimeInterval

    /// Live subscribers to "an exchange was just parked" (`pendingBreakpointStream`).
    private var pendingContinuations: [UUID: AsyncStream<PendingBreakpoint>.Continuation] = [:]

    /// The most recently armed watchdog, and how many watchdogs actually
    /// auto-proceeded a hold. Both exist so a test can assert cancellation
    /// *positively* — await the task, then check it resolved nothing — instead of
    /// sleeping past the deadline and inferring cancellation from silence.
    private var lastWatchdog: Task<Void, Never>?
    private var timeoutResolutionCount = 0

    /// Test seam: called immediately before a parked exchange is announced on
    /// `pendingStream()`, with the lock released.
    ///
    /// It exists because the ordering it observes — watchdog armed *before* the
    /// announcement — can only otherwise be checked by reading `mostRecentWatchdog`
    /// straight after receiving an announcement, and that check passes either way on
    /// a fast machine: the window between the two is microseconds, far shorter than
    /// it takes a subscriber to be scheduled. That is precisely how the ordering bug
    /// this guards survived until Thread Sanitizer slowed the tail of `hold` down
    /// enough to lose the race on CI. A hook at the exact moment is deterministic;
    /// a timing-dependent assertion is not a guard, it is a coin toss.
    var willAnnounceParked: (@Sendable () -> Void)?

    /// Awaitable handle on the watchdog armed by the last `hold`.
    var mostRecentWatchdog: Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return lastWatchdog
    }

    /// Holds released by the timeout rather than by a resume/disarm/cancel.
    var timeoutResolutions: Int {
        lock.lock()
        defer { lock.unlock() }
        return timeoutResolutionCount
    }

    private func countTimeoutResolution() {
        lock.lock()
        timeoutResolutionCount += 1
        lock.unlock()
    }

    init(timeout: TimeInterval = 300) {
        self.timeout = timeout
    }

    // MARK: - Armed breakpoints (actor-facing)

    func arm(_ breakpoint: Breakpoint) {
        lock.lock(); defer { lock.unlock() }
        breakpoints.append(breakpoint)
    }

    /// Remove an armed breakpoint; returns false when no such id exists.
    ///
    /// Disarming also **releases every exchange this breakpoint is still holding**
    /// (proceeding unchanged). Without that, an operator who disarms a breakpoint
    /// leaves the already-parked connections hanging until the timeout expires —
    /// minutes of a live client connection held open by a breakpoint that no
    /// longer exists.
    func disarm(id: UUID) -> Bool {
        lock.lock()
        let before = breakpoints.count
        breakpoints.removeAll { $0.id == id }
        let removed = breakpoints.count != before
        let orphaned = held.values.filter { $0.info.breakpointID == id }.map(\.info.id)
        lock.unlock()

        for pendingID in orphaned {
            resolve(pendingID: pendingID, resolution: .proceed(.none))
        }
        return removed
    }

    func armed() -> [Breakpoint] {
        lock.lock(); defer { lock.unlock() }
        return breakpoints
    }

    func pending() -> [PendingBreakpoint] {
        lock.lock(); defer { lock.unlock() }
        return held.values.map(\.info).sorted { $0.heldAt < $1.heldAt }
    }

    /// Test seam: `cancelledBeforePark` must never retain an id past the `hold`
    /// that owns it. Anything left behind is a leak that grows for the life of the
    /// process, and this is the only collection in the engine without a cap —
    /// it's meant to be transient, so the assertion is "empty", not "bounded".
    var cancelledBeforeParkCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cancelledBeforePark.count
    }

    /// A live "just parked" stream, so an operator waiting for a breakpoint to fire
    /// doesn't poll `pending()`. Bounded like every other stream in the engine; a
    /// hold pins a live connection, so 64 pending-but-unread holds already means
    /// something is badly wrong, and a drop is logged rather than swallowed.
    func pendingStream() -> AsyncStream<PendingBreakpoint> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            lock.lock()
            pendingContinuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.pendingContinuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    /// Fan a newly parked exchange out to the waiters. Called with the lock *not*
    /// held: `yield` can resume a suspended consumer, and doing that under the lock
    /// would let a waiter's continuation run while forwarding still owns it.
    private func broadcast(parked info: PendingBreakpoint) {
        lock.lock()
        let continuations = pendingContinuations
        lock.unlock()
        for (id, continuation) in continuations {
            if case .dropped = continuation.yield(info) {
                Log.proxy.error("""
                A breakpoint-hold notification was dropped for a subscriber that isn't keeping up \
                (\(id, privacy: .public)); the exchange \(info.id, privacy: .public) is still held \
                and still listed by list_pending.
                """)
            }
        }
    }

    /// The first armed breakpoint that matches this request on `phase`, or nil.
    /// Matching runs off the *original* request (method/url) plus its `origin`,
    /// exactly like rules — so "break only my app's calls" works, and a breakpoint
    /// scoped to a client never holds a different client's traffic.
    func firstMatch(
        method: String, url: String, phase: BreakpointPhase, origin: RequestOrigin? = nil
    ) -> Breakpoint? {
        lock.lock(); defer { lock.unlock() }
        return breakpoints.first { bp in
            (phase == .request ? bp.onRequest : bp.onResponse)
                && bp.match.matches(method: method, url: url, origin: origin)
        }
    }

    // MARK: - Resume (actor-facing)

    /// Release a held exchange. Returns false when the id isn't held (already
    /// resumed or timed out) — the caller turns that into a not-found error.
    @discardableResult
    func resume(pendingID: UUID, resolution: BreakpointResolution) -> Bool {
        resolve(pendingID: pendingID, resolution: resolution)
    }

    // MARK: - Hold (forwarding-facing)

    /// Park `info` and suspend until `resume` (or the timeout) delivers a decision.
    /// The timeout auto-proceeds unchanged — the least surprising outcome for a
    /// client left waiting on an unattended breakpoint.
    ///
    /// Cancellation-aware: if the forwarding task is cancelled while parked (the
    /// client hung up, so `StreamRelay` tore down the stream), the hold resolves
    /// as `.abort` immediately instead of waiting out the timeout. Otherwise the
    /// entry would linger and `list_pending` would keep advertising an exchange
    /// nobody is waiting on.
    func hold(_ info: PendingBreakpoint) async -> BreakpointResolution {
        // The marker below is only ever meaningful to *this* call, so clear it on
        // the way out. `cancel` writes one whenever it finds no held entry, and
        // "no held entry" has a second meaning it can't distinguish: not *yet*
        // parked (the marker gets consumed) versus *already resolved* by resume,
        // disarm or the watchdog — in which case nothing would ever consume it and
        // the id stays in the set for the life of the process. That second case is
        // reachable whenever a client hangs up at the same moment an operator
        // resumes, which is an ordinary pairing for a hold that pins a live
        // connection. `withTaskCancellationHandler` has deregistered its handler by
        // the time it returns, so no insert can follow this defer.
        defer {
            lock.lock()
            cancelledBeforePark.remove(info.id)
            lock.unlock()
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<BreakpointResolution, Never>) in
                lock.lock()
                // Cancelled in the window before we got here — don't park at all.
                if cancelledBeforePark.remove(info.id) != nil {
                    lock.unlock()
                    continuation.resume(returning: .abort)
                    return
                }
                held[info.id] = Held(info: info, continuation: continuation, timeout: nil)
                lock.unlock()

                let id = info.id
                let seconds = self.timeout
                let task = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    if self?.resolve(pendingID: id, resolution: .proceed(.none)) == true {
                        self?.countTimeoutResolution()
                    }
                }

                // Record and attach the watchdog in one critical section, then
                // announce. `lastWatchdog` is the test seam for proving cancellation
                // positively (await the task, then check it resolved nothing) instead
                // of sleeping past a deadline and inferring it from silence.
                //
                // The announcement goes *last* on purpose. It used to come first, on
                // the reasoning that a parked exchange is already resumable and a
                // `wait_for_pending` caller shouldn't wait — true, but it made the
                // announcement arrive before the watchdog existed, so anything treating
                // "announced" as "fully parked" was racing this function's own tail.
                // `BreakpointTests.resolvingAHold_cancelsTheTimeoutWatchdog` did exactly
                // that and went red under TSan, which widens the window. Moving it here
                // costs the waiter a task creation and two lock acquisitions — not a
                // delay of any consequence — and buys an ordering guarantee: an
                // announced hold has its watchdog armed.
                lock.lock()
                lastWatchdog = task
                // A short timeout can already have resolved the hold by now (tests use
                // 50 ms), in which case there is nothing left to attach it to.
                let stillHeld = held[id] != nil
                if stillHeld { held[id]?.timeout = task }
                lock.unlock()

                if stillHeld {
                    willAnnounceParked?()
                    broadcast(parked: info)
                } else {
                    // Resolved already — announcing it now would hand a waiter an
                    // exchange it cannot act on, which is the one thing the pending
                    // stream must not do.
                    task.cancel()
                }
            }
        } onCancel: {
            cancel(pendingID: info.id)
        }
    }

    /// Resolve a hold as aborted because its task was cancelled. If the body hasn't
    /// parked yet, leave a marker so it aborts instead of parking.
    private func cancel(pendingID: UUID) {
        lock.lock()
        guard let entry = held.removeValue(forKey: pendingID) else {
            cancelledBeforePark.insert(pendingID)
            lock.unlock()
            return
        }
        lock.unlock()
        entry.timeout?.cancel()
        entry.continuation.resume(returning: .abort)
    }

    /// Remove the held entry and resume its continuation exactly once. The lock
    /// guarantees only the first caller (resume vs. timeout vs. disarm vs. cancel)
    /// wins, so the continuation is never resumed twice.
    @discardableResult
    private func resolve(pendingID: UUID, resolution: BreakpointResolution) -> Bool {
        lock.lock()
        guard let entry = held.removeValue(forKey: pendingID) else {
            lock.unlock()
            return false
        }
        lock.unlock()
        entry.timeout?.cancel()
        entry.continuation.resume(returning: resolution)
        return true
    }
}
