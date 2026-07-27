import Foundation
import LoomSharedModels

/// `BreakpointControlling`. The held exchanges live in `BreakpointStore`, off
/// the actor, so `BreakpointForwarder` can check for a breakpoint on the event
/// loop without hopping here — these methods are the control surface over it.
extension ProxyEngine {
    public func armBreakpoint(_ breakpoint: Breakpoint) async throws {
        if let reason = breakpoint.validationError {
            throw ProxyControlError.invalidBreakpoint(reason)
        }
        breakpointStore.arm(breakpoint)
    }

    public func disarmBreakpoint(id: UUID) async throws {
        guard breakpointStore.disarm(id: id) else {
            throw ProxyControlError.breakpointNotFound(id)
        }
    }

    public func armedBreakpoints() async -> [Breakpoint] {
        breakpointStore.armed()
    }

    public func pendingBreakpoints() async -> [PendingBreakpoint] {
        breakpointStore.pending()
    }

    public func pendingBreakpointStream() async -> AsyncStream<PendingBreakpoint> {
        breakpointStore.pendingStream()
    }

    public func resumeBreakpoint(pendingID: UUID, abort: Bool, edit: BreakpointEdit) async throws {
        let resolution: BreakpointResolution = abort ? .abort : .proceed(edit)
        guard breakpointStore.resume(pendingID: pendingID, resolution: resolution) else {
            throw ProxyControlError.pendingBreakpointNotFound(pendingID)
        }
    }
}
