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
    /// Matching runs off the *original* request (method/url), exactly like rules.
    func firstMatch(method: String, url: String, phase: BreakpointPhase) -> Breakpoint? {
        lock.lock(); defer { lock.unlock() }
        return breakpoints.first { bp in
            (phase == .request ? bp.onRequest : bp.onResponse) && bp.match.matches(method: method, url: url)
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
        await withTaskCancellationHandler {
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

                // Tell the waiters before arming the watchdog: the exchange is
                // already parked and resumable at this point, and a `wait_for_pending`
                // caller should hear about it with no polling delay.
                broadcast(parked: info)

                let id = info.id
                let seconds = self.timeout
                let task = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.resolve(pendingID: id, resolution: .proceed(.none))
                }

                // Attach the watchdog. A short timeout can already have resolved the
                // hold by now (tests use 50 ms), in which case there's nothing left
                // to attach it to and the task is redundant.
                lock.lock()
                if held[id] != nil {
                    held[id]?.timeout = task
                    lock.unlock()
                } else {
                    lock.unlock()
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
