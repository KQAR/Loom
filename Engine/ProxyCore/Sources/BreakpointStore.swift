import Foundation
import SharedModels

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

    /// A parked exchange plus the continuation that releases its `await`.
    private struct Held {
        var info: PendingBreakpoint
        var continuation: CheckedContinuation<BreakpointResolution, Never>
    }

    /// How long a held exchange waits before auto-proceeding unchanged, so a client
    /// connection can't hang forever if no operator ever resumes it.
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 300) {
        self.timeout = timeout
    }

    // MARK: - Armed breakpoints (actor-facing)

    func arm(_ breakpoint: Breakpoint) {
        lock.lock(); defer { lock.unlock() }
        breakpoints.append(breakpoint)
    }

    /// Remove an armed breakpoint; returns false when no such id exists.
    func disarm(id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let before = breakpoints.count
        breakpoints.removeAll { $0.id == id }
        return breakpoints.count != before
    }

    func armed() -> [Breakpoint] {
        lock.lock(); defer { lock.unlock() }
        return breakpoints
    }

    func pending() -> [PendingBreakpoint] {
        lock.lock(); defer { lock.unlock() }
        return held.values.map(\.info).sorted { $0.heldAt < $1.heldAt }
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
    func hold(_ info: PendingBreakpoint) async -> BreakpointResolution {
        await withCheckedContinuation { (continuation: CheckedContinuation<BreakpointResolution, Never>) in
            lock.lock()
            held[info.id] = Held(info: info, continuation: continuation)
            lock.unlock()

            let id = info.id
            let timeout = self.timeout
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.resolve(pendingID: id, resolution: .proceed(.none))
            }
        }
    }

    /// Remove the held entry and resume its continuation exactly once. The lock
    /// guarantees only the first caller (resume vs. timeout) wins, so the
    /// continuation is never resumed twice.
    @discardableResult
    private func resolve(pendingID: UUID, resolution: BreakpointResolution) -> Bool {
        lock.lock()
        guard let entry = held.removeValue(forKey: pendingID) else {
            lock.unlock()
            return false
        }
        lock.unlock()
        entry.continuation.resume(returning: resolution)
        return true
    }
}
