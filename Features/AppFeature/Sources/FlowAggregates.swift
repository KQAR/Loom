import Foundation
import LoomSharedModels

/// The sidebar's per-host / per-app / per-device counters and the error badge,
/// maintained incrementally as flows arrive.
///
/// **Why incremental at all** (the constraint, unchanged from when these lived on
/// `AppFeature.State` directly): recomputing them by scanning the flow list on each
/// render was four separate O(n) passes — hosts, apps, devices, errors — and the host
/// pass parsed 2000 URLs through `URLComponents` every time.
///
/// **Why one type**: the six fields are not six independent counters, they are one
/// projection of the flow list, and three operations have to agree about them.
/// `contribute` and `retract` must stay exact mirror images or a replaced flow leaks a
/// count; `removeAll` must clear exactly this set or a cleared capture leaves a
/// sidebar full of hosts with no rows behind them. Spread across `State`, adding a
/// seventh aggregate meant remembering three separate places to touch — and nothing
/// failed if you forgot one, it just drifted. Here the compiler shows you all three.
///
/// Deliberately *not* included: `pinnedHosts`, `pinnedApps`, `deviceAliases`. Those
/// look adjacent but are the opposite kind of thing — user preferences persisted to
/// disk, which must **survive** `forgetCapturedFlows()`. Folding them in here would
/// make clearing the capture silently unpin everything.
struct FlowAggregates: Equatable {
    /// Read-only from outside; every mutation goes through the three operations below,
    /// which is what keeps them in step.
    private(set) var hostCounts: [String: Int] = [:]
    private(set) var appCounts: [String: Int] = [:]
    private(set) var appReps: [String: SourceApp] = [:]
    private(set) var deviceCounts: [String: Int] = [:]
    private(set) var deviceReps: [String: SourceDevice] = [:]
    /// Flows that failed or answered 4xx/5xx — the sidebar's Errors badge.
    private(set) var errorCount = 0
    /// `flow id → host`, so the host-filtered list is a dictionary lookup per row
    /// instead of a scan of the URL string.
    ///
    /// This is the same host `hostCounts` is keyed by, computed in the same place —
    /// which is why it is nearly free to keep, and why matching on it is *more*
    /// correct than re-deriving the host per row: the sidebar's categories are these
    /// values, so a row belongs to a category exactly when its cached host equals it.
    /// Measured on a full 2000-flow ring, host-filtered: 3.2 ms per render before,
    /// 0.1 ms after — and `displayFlows` is read on every render while scrolling.
    private(set) var hostByFlow: [Flow.ID: String] = [:]

    /// Whether a flow counts as a failure for the Errors category/badge. One
    /// definition, used by both the count and the list filter.
    ///
    /// `flowError != nil` rather than `error != nil`: the latter reaches through to
    /// `FlowError.message`, and this runs once per row on every render of the Errors
    /// list. Same answer, no string.
    static func isError(_ flow: Flow) -> Bool {
        switch flow.outcome {
        case .failed: true
        case let .completed(response, _): response.statusCode >= 400
        case let .streaming(response): response.statusCode >= 400
        case .pending: false
        }
    }

    /// Fold one flow in.
    mutating func contribute(_ flow: Flow) {
        if Self.isError(flow) { errorCount += 1 }
        if let host = flow.host {
            hostCounts[host, default: 0] += 1
            hostByFlow[flow.id] = host
        }
        if let app = flow.sourceApp {
            appCounts[app.groupingKey, default: 0] += 1
            appReps[app.groupingKey] = app
        }
        if let device = flow.sourceDevice {
            let key = device.groupingKey
            deviceCounts[key, default: 0] += 1
            if var existing = deviceReps[key] {
                // Keep the richest typing seen across the device's flows.
                if existing.platform == nil { existing.platform = device.platform }
                if existing.client == nil { existing.client = device.client }
                deviceReps[key] = existing
            } else {
                deviceReps[key] = device
            }
        }
    }

    /// Undo `contribute` — for a replaced or evicted flow. A key that reaches zero is
    /// removed along with its representative, so an emptied host/app/device disappears
    /// from the sidebar instead of lingering at 0.
    mutating func retract(_ flow: Flow) {
        if Self.isError(flow) { errorCount = max(0, errorCount - 1) }
        if let host = flow.host {
            _ = Self.decrement(&hostCounts, key: host)
            hostByFlow[flow.id] = nil
        }
        if let app = flow.sourceApp, Self.decrement(&appCounts, key: app.groupingKey) {
            appReps[app.groupingKey] = nil
        }
        if let device = flow.sourceDevice, Self.decrement(&deviceCounts, key: device.groupingKey) {
            deviceReps[device.groupingKey] = nil
        }
    }

    /// Drop everything. Assigning a fresh value rather than clearing six containers by
    /// hand: a new aggregate added above is then reset for free, which is the failure
    /// mode a hand-written reset has.
    mutating func removeAll() {
        self = FlowAggregates()
    }

    /// Decrement a count, removing the key at zero. Returns whether it emptied.
    /// Static so passing one of our own dictionaries `inout` isn't an overlapping
    /// access to `self`.
    private static func decrement(_ counts: inout [String: Int], key: String) -> Bool {
        guard let count = counts[key] else { return false }
        if count <= 1 {
            counts[key] = nil
            return true
        }
        counts[key] = count - 1
        return false
    }
}
