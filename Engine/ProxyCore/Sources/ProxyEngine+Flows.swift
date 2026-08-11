import Foundation
import LoomSharedModels

/// `FlowProviding` + `CaptureControlling`: reading captured traffic, the live
/// streams, and the capture gate. Thin by design — the retention policy, the
/// ring, the read-through to SQLite and the O(1) upsert all live in `FlowStore`;
/// the engine only exposes them.
extension ProxyEngine {
    public func status() async -> ProxyStatus {
        let refusals = RefusalLog.shared.snapshot()
        return ProxyStatus(
            isRunning: running,
            port: boundPort,
            capturedCount: await store.count,
            retainedCount: await store.retainedCount,
            isRecording: await store.isRecording,
            listenHost: currentBindHost,
            socksPort: boundSOCKSPort,
            recentRefusals: refusals.recent,
            refusedConnections: refusals.total,
            reverseProxies: reverseProxyConfig.snapshot()
        )
    }

    public func recentFlows(limit: Int) async -> [Flow] {
        await store.recent(limit: limit)
    }

    /// Filtered read over everything retained — the in-memory ring first, then the
    /// durable store, so a match is findable whether or not it is among the newest
    /// `limit` exchanges *or* still in memory.
    public func recentFlows(matching query: FlowQuery, limit: Int) async -> [Flow] {
        await store.recent(matching: query, limit: limit)
    }

    /// The same read with its bound attached, for callers that report to an agent —
    /// an empty result must be able to say whether it means "not captured" or "not
    /// searched".
    public func searchFlows(matching query: FlowQuery, limit: Int) async -> FlowSearchResult {
        await store.search(matching: query, limit: limit)
    }

    /// Per-host / per-app / per-device counts over everything retained.
    ///
    /// `coversHistory` is false only in the window between boot and the history
    /// aggregation landing, when the numbers cover the restored ring alone — a
    /// distinction the surface reading them needs, because "12" and "12 so far" are
    /// different claims and only one of them should be shown as final.
    public func flowAggregates() async -> (aggregates: FlowAggregates, coversHistory: Bool) {
        await store.flowAggregates()
    }

    /// One page of the capture, newest-first — ring and durable store merged in order.
    ///
    /// Loom's own caller does not page: the main window asks once at boot and holds what
    /// it gets. What this read is actually for is the merge, and `FlowStore.page` has the
    /// rest of that story.
    public func flowPage(
        after cursor: FlowCursor?, limit: Int, matching query: FlowQuery
    ) async -> FlowPage {
        await store.page(after: cursor, limit: limit, matching: query)
    }

    /// Recent flows with bodies hydrated from disk — for HAR export and any other
    /// consumer that needs the full payload, not just summaries. `recentFlows`
    /// stays body-free so list/summary reads don't pay to load bodies.
    public func recentFlowsForExport(limit: Int) async -> [Flow] {
        await store.recentHydrated(limit: limit)
    }

    public func flow(id: UUID) async -> Flow? {
        await store.flow(id: id)
    }

    /// Live fan-out of flow captures/updates. See `FlowProviding.flowStream()`
    /// for the emission contract (same id emitted on start + each state change,
    /// WS per-frame re-emits, replays carry `replayedFrom`, late subscribers miss
    /// history). `FlowObserving` delivers the identical sequence, pushed.
    /// Fires when the captured set is discarded, by whoever asked. See
    /// `FlowProviding.flowsClearedStream()`.
    public func flowsClearedStream() async -> AsyncStream<Void> {
        await store.clearedStream()
    }

    public func flowStream() async -> AsyncStream<Flow> {
        await store.stream()
    }

    /// Aggregate captured flows by originating device (keyed on remote IP). LAN
    /// devices sort ahead of this Mac, then by most-recently-seen — the phone you
    /// just pointed at Loom floats to the top.
    /// Live count of LAN devices connected to the proxy this session (excludes this
    /// Mac). Connection-derived, so it reflects a phone that has connected even
    /// before/without any captured flow — unlike the flow-derived `connectedDevices`.
    public func connectedDeviceCountStream() async -> AsyncStream<Int> {
        await store.connectedDeviceCountStream()
    }

    public func connectedDevices() async -> [DeviceSummary] {
        // One actor hop, not two: `recent(limit:)` clamps to what's in the ring, so
        // asking for a ring's worth is the same answer `await store.count` would
        // have given — without a second hop the store could change across.
        let flows = await store.recent(limit: flowCapacity)
        var byIP: [String: DeviceSummary] = [:]
        for flow in flows {
            guard let device = flow.sourceDevice else { continue }
            let at = flow.startedAt
            if var summary = byIP[device.groupingKey] {
                summary.flowCount += 1
                if at > summary.lastActive { summary.lastActive = at }
                // Keep the richest typing seen for this device across its flows.
                if summary.device.platform == nil { summary.device.platform = device.platform }
                if summary.device.client == nil { summary.device.client = device.client }
                byIP[device.groupingKey] = summary
            } else {
                byIP[device.groupingKey] = DeviceSummary(device: device, flowCount: 1, lastActive: at)
            }
        }
        return byIP.values.sorted { a, b in
            if (a.device.kind == .lan) != (b.device.kind == .lan) { return a.device.kind == .lan }
            return a.lastActive > b.lastActive
        }
    }

    // MARK: - CaptureControlling

    /// Pause/resume recording. Forwarding (and MITM decryption) is unaffected;
    /// paused means observed traffic just isn't stored as flows.
    public func setRecording(_ recording: Bool) async {
        await store.setRecording(recording)
    }

    /// Ingest flows that never crossed this machine's wire (a HAR import).
    ///
    /// `force: true` — an import is an explicit action, so it lands even while capture
    /// is paused, exactly like a replay. Imported flows are labelled
    /// (`Flow.importedFrom`) and otherwise ordinary: they persist, they appear on
    /// `flowStream()`, and `replay_flow` / `diff_flows` work on them.
    public func importFlows(_ flows: [Flow]) async -> Int {
        for flow in flows {
            await store.upsert(flow, force: true)
        }
        return flows.count
    }

    /// Generate-or-load the CA once. Failure leaves interception unavailable but

    public func clearFlows() async {
        await store.clear()
    }

    /// Persist everything to disk before the app dies. Call from the terminate
    /// handler. Two gaps closed: (1) flows still in flight (`.pending`/streaming)
    /// live only in the ring and never got saved — finalize them as interrupted
    /// and write them; (2) completed flows are saved fire-and-forget, so drain the
}
