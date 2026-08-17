import Foundation

/// Per-host / per-app / per-device / record-kind counters and the error count,
/// maintained incrementally as flows arrive.
///
/// **Owned by the engine, over everything retained.** It used to be the window's, over
/// the flows the window happened to hold — which made every sidebar badge a count of
/// the newest 2 000 exchanges while the store kept 20 000. `api.example.com  12` next
/// to a store holding 300 of them is not a smaller truth, it is a wrong number, and it
/// was wrong in the direction that hides work: a host with no recent traffic vanished
/// from the sidebar entirely while its flows sat on disk, searchable and unlisted. The
/// windowed list makes it unavoidable as well as wrong — once the window holds ~120
/// rows, counts derived from it would be off by two orders of magnitude.
///
/// **Why incremental at all** (the constraint, unchanged from when these lived on
/// `AppFeature.State` directly): recomputing them by scanning the flow list on each
/// render was four separate O(n) passes — hosts, apps, devices, errors — and the host
/// pass parsed 2000 URLs through `URLComponents` every time.
///
/// **Why one type**: these fields are not independent counters, they are one
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
public struct FlowAggregates: Equatable, Sendable {
    /// Read-only from outside; every mutation goes through the three operations below,
    /// which is what keeps them in step.
    public private(set) var hostCounts: [String: Int] = [:]
    public private(set) var appCounts: [String: Int] = [:]
    public private(set) var appReps: [String: SourceApp] = [:]
    /// `device key → app key → count`. The sidebar nests apps under the device
    /// they ran on, and that needs a *joint* count: `appCounts` alone cannot say
    /// how many of Safari's flows came from the phone rather than this Mac, and
    /// splitting it after the fact would need the flows back.
    ///
    /// Bounded by devices × distinct apps, not by flows — the same shape as the
    /// counters beside it, which is the property that let these move to the engine
    /// (see the note on `hostByRow` below).
    public private(set) var deviceAppCounts: [String: [String: Int]] = [:]
    public private(set) var deviceCounts: [String: Int] = [:]
    public private(set) var deviceReps: [String: SourceDevice] = [:]
    /// Flows that failed or answered 4xx/5xx — the sidebar's Errors badge.
    public private(set) var errorCount = 0
    /// HTTP exchanges and connection diagnostics are two grains in one retained store.
    public private(set) var exchangeCount = 0
    public private(set) var connectionCount = 0
    public private(set) var connectionFailureCount = 0
    public private(set) var relayedConnectionCount = 0
    /// Deliberately **not** here: a `flow id → host` map. It used to live alongside
    /// these counters and it is the one field that scales with the number of flows
    /// rather than the number of distinct hosts — which is precisely what an aggregate
    /// held over everything retained (20 000 rows, not 2 000) must not do. A per-flow
    /// projection belongs to whoever is holding those flows; see
    /// `AppFeature.State.hostByRow`, which keeps it for the rows the window has.

    public init() {}

    /// Whether a flow counts as a failure for the Errors category/badge. One
    /// definition, used by both the count and the list filter.
    ///
    /// `flowError != nil` rather than `error != nil`: the latter reaches through to
    /// `FlowError.message`, and this runs once per row on every render of the Errors
    /// list. Same answer, no string.
    public static func isError(_ flow: Flow) -> Bool {
        switch flow.outcome {
        case .failed: true
        case let .completed(response, _): response.statusCode >= 400
        case let .streaming(response): response.statusCode >= 400
        case .pending: false
        }
    }

    /// Fold one flow in.
    public mutating func contribute(_ flow: Flow) {
        if flow.recordKind == .tunnel {
            connectionCount += 1
            if Self.isError(flow) {
                connectionFailureCount += 1
            } else {
                relayedConnectionCount += 1
            }
        } else {
            exchangeCount += 1
        }
        if Self.isError(flow) { errorCount += 1 }
        if let host = flow.host {
            hostCounts[host, default: 0] += 1
        }
        if let app = flow.sourceApp {
            appCounts[app.groupingKey, default: 0] += 1
            appReps[app.groupingKey] = app
            if let deviceKey = flow.sourceDevice?.groupingKey {
                deviceAppCounts[deviceKey, default: [:]][app.groupingKey, default: 0] += 1
            }
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

    /// Fold in many flows that share a value, in one step — what a `GROUP BY` over a
    /// store hands back (`FlowPersistence.aggregate`), where the count arrives already
    /// summed and the flows themselves are never materialized.
    ///
    /// These are `contribute` split by field and given a multiplicity, not a second way
    /// to count: each does exactly what `contribute` does for its own field, so folding
    /// a capture row-by-row and folding it grouped must produce the same value. That is
    /// what `FlowPersistenceAggregateTests` pins, and it is the only reason the store is
    /// allowed to skip decoding.
    public mutating func addHost(_ host: String, count: Int) {
        guard count > 0 else { return }
        hostCounts[host, default: 0] += count
    }

    public mutating func addApp(_ app: SourceApp, count: Int) {
        guard count > 0 else { return }
        appCounts[app.groupingKey, default: 0] += count
        appReps[app.groupingKey] = app
    }

    /// The joint count, which the store hands back as its own `GROUP BY` rather
    /// than as something derivable from the two single-field ones — an app's flows
    /// and a device's flows overlap in a way neither total records.
    public mutating func addDeviceApp(deviceKey: String, appKey: String, count: Int) {
        guard count > 0 else { return }
        deviceAppCounts[deviceKey, default: [:]][appKey, default: 0] += count
    }

    public mutating func addDevice(_ device: SourceDevice, count: Int) {
        guard count > 0 else { return }
        let key = device.groupingKey
        deviceCounts[key, default: 0] += count
        if var existing = deviceReps[key] {
            // The same "keep the richest typing seen" merge `contribute` does.
            if existing.platform == nil { existing.platform = device.platform }
            if existing.client == nil { existing.client = device.client }
            deviceReps[key] = existing
        } else {
            deviceReps[key] = device
        }
    }

    public mutating func addErrors(_ count: Int) {
        guard count > 0 else { return }
        errorCount += count
    }

    public mutating func addRecordCounts(
        exchanges: Int, connections: Int, connectionFailures: Int
    ) {
        exchangeCount += max(0, exchanges)
        connectionCount += max(0, connections)
        connectionFailureCount += max(0, connectionFailures)
        relayedConnectionCount += max(0, connections - connectionFailures)
    }

    /// Undo `contribute` — for a replaced or evicted flow. A key that reaches zero is
    /// removed along with its representative, so an emptied host/app/device disappears
    /// from the sidebar instead of lingering at 0.
    public mutating func retract(_ flow: Flow) {
        if flow.recordKind == .tunnel {
            connectionCount = max(0, connectionCount - 1)
            if Self.isError(flow) {
                connectionFailureCount = max(0, connectionFailureCount - 1)
            } else {
                relayedConnectionCount = max(0, relayedConnectionCount - 1)
            }
        } else {
            exchangeCount = max(0, exchangeCount - 1)
        }
        if Self.isError(flow) { errorCount = max(0, errorCount - 1) }
        if let host = flow.host {
            _ = Self.decrement(&hostCounts, key: host)
        }
        if let app = flow.sourceApp {
            if Self.decrement(&appCounts, key: app.groupingKey) {
                appReps[app.groupingKey] = nil
            }
            if let deviceKey = flow.sourceDevice?.groupingKey,
               var apps = deviceAppCounts[deviceKey] {
                // An emptied pair drops out, and an emptied device's map with it —
                // otherwise a device that has gone quiet keeps an empty disclosure
                // group open under it forever.
                _ = Self.decrement(&apps, key: app.groupingKey)
                deviceAppCounts[deviceKey] = apps.isEmpty ? nil : apps
            }
        }
        if let device = flow.sourceDevice, Self.decrement(&deviceCounts, key: device.groupingKey) {
            deviceReps[device.groupingKey] = nil
        }
    }

    /// Drop everything. Assigning a fresh value rather than clearing six containers by
    /// hand: a new aggregate added above is then reset for free, which is the failure
    /// mode a hand-written reset has.
    public mutating func removeAll() {
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
