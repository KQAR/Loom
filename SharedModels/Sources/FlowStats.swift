import Foundation

/// How flows are bucketed by `FlowStats`.
public enum FlowGrouping: String, Sendable, CaseIterable {
    /// By request host — "which service is failing / slow".
    case host
    /// By method + path with the query stripped and id-looking segments collapsed —
    /// "which endpoint", so `/orders/1` and `/orders/2` land in one bucket.
    case endpoint
    /// By status class (`2xx`, `4xx`, `failed`, …).
    case status
    /// By originating local app.
    case app
    /// By originating device.
    case device
    /// One bucket for everything.
    case none
}

/// Aggregates over captured flows: counts, error rates and latency percentiles per
/// host / endpoint / status / app / device.
///
/// Why it exists: "which endpoint is slow" and "what share of calls are failing" were
/// only answerable by pulling flow summaries and doing arithmetic in an agent's
/// context — expensive per question, and wrong past the page size, since a percentile
/// over the newest 20 exchanges is not a percentile. The aggregation is cheap
/// (metadata only, one pass, no bodies), so it belongs next to the store.
///
/// Everything here is derived from timestamps and status codes, which survive body
/// slimming — so a stat is as accurate for a flow whose body has been evicted as for
/// a live one. The one exception is byte totals: a body's size is only known while the
/// bytes are around (or, when the capture was truncated, from the recorded wire size),
/// so each bucket reports `sizeUnknownFlows` rather than quietly under-counting.
public struct FlowStats: Equatable, Sendable {
    /// A latency distribution. Nil when no flow in the bucket recorded that phase
    /// (e.g. nothing completed yet).
    public struct Distribution: Equatable, Sendable {
        public var p50: Int
        public var p95: Int
        public var max: Int
        public var samples: Int

        public init(p50: Int, p95: Int, max: Int, samples: Int) {
            self.p50 = p50
            self.p95 = p95
            self.max = max
            self.samples = samples
        }

        /// Percentiles by nearest-rank on a sorted sample — no interpolation, so every
        /// reported number is a latency some request actually had.
        static func from(_ samples: [Int]) -> Distribution? {
            guard !samples.isEmpty else { return nil }
            let sorted = samples.sorted()
            func percentile(_ fraction: Double) -> Int {
                let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
                return sorted[min(max(rank, 0), sorted.count - 1)]
            }
            return Distribution(
                p50: percentile(0.5), p95: percentile(0.95),
                max: sorted[sorted.count - 1], samples: sorted.count
            )
        }
    }

    public struct Bucket: Equatable, Sendable {
        /// Host, endpoint, status class, app or device — whatever was grouped on.
        public var key: String
        public var flows: Int
        /// Transport failures plus status >= 400.
        public var errors: Int
        /// Transport failures alone (no response at all).
        public var failed: Int
        /// Still in flight — counted, but excluded from error/latency figures.
        public var inFlight: Int
        /// Count per status class: `2xx`, `3xx`, `4xx`, `5xx`, `1xx`, `failed`.
        public var statusClasses: [String: Int]
        /// Server think-time (request sent → response head).
        public var ttfb: Distribution?
        /// Whole exchange (request start → last byte).
        public var duration: Distribution?
        public var requestBytes: Int
        public var responseBytes: Int
        /// Flows whose body size isn't known (body evicted and not truncated), so byte
        /// totals are a floor rather than a total.
        public var sizeUnknownFlows: Int

        public var errorRate: Double {
            let considered = flows - inFlight
            guard considered > 0 else { return 0 }
            return Double(errors) / Double(considered)
        }
    }

    /// Every matching flow in one bucket.
    public var total: Bucket
    /// Buckets, biggest first, capped by the caller's limit.
    public var buckets: [Bucket]
    /// Buckets dropped by that cap — never silently omitted.
    public var bucketsOmitted: Int
    /// The slowest completed exchanges by TTFB, so "which one" is answerable without
    /// a second query.
    public var slowest: [Slow]
    public var earliest: Date?
    public var latest: Date?

    public struct Slow: Equatable, Sendable {
        public var id: UUID
        public var method: String
        public var url: String
        public var statusCode: Int?
        public var ttfbMS: Int?
        public var durationMS: Int?
    }

    /// One pass over `flows` (newest-first or oldest-first, order doesn't matter).
    ///
    /// - Parameters:
    ///   - grouping: what to bucket by.
    ///   - limit: how many buckets to return (biggest first); the rest are counted in
    ///     `bucketsOmitted`.
    ///   - slowest: how many slowest-by-TTFB exchanges to name.
    public static func compute(
        flows: [Flow], grouping: FlowGrouping, limit: Int = 10, slowest slowestCount: Int = 3
    ) -> FlowStats {
        var accumulators: [String: Accumulator] = [:]
        var totals = Accumulator()
        var earliest: Date?
        var latest: Date?

        for flow in flows {
            totals.add(flow)
            if grouping != .none {
                accumulators[key(for: flow, grouping: grouping), default: Accumulator()].add(flow)
            }
            if earliest == nil || flow.startedAt < earliest! { earliest = flow.startedAt }
            if latest == nil || flow.startedAt > latest! { latest = flow.startedAt }
        }

        let ranked = accumulators
            .map { $0.value.bucket(key: $0.key) }
            // Ties broken by key so the output is stable across identical captures
            // (an agent diffing two runs shouldn't see phantom reordering).
            .sorted { ($0.flows, $1.key) > ($1.flows, $0.key) }
        let kept = Array(ranked.prefix(max(0, limit)))

        let slowest = flows
            .filter { $0.ttfbMS != nil }
            .sorted { ($0.ttfbMS ?? 0) > ($1.ttfbMS ?? 0) }
            .prefix(max(0, slowestCount))
            .map {
                Slow(
                    id: $0.id, method: $0.request.method, url: $0.request.url,
                    statusCode: $0.statusCode, ttfbMS: $0.ttfbMS, durationMS: $0.durationMS
                )
            }

        return FlowStats(
            total: totals.bucket(key: "all"),
            buckets: kept,
            bucketsOmitted: ranked.count - kept.count,
            slowest: Array(slowest),
            earliest: earliest,
            latest: latest
        )
    }

    /// The bucket key for one flow.
    public static func key(for flow: Flow, grouping: FlowGrouping) -> String {
        switch grouping {
        case .host:
            return flow.host ?? "(unknown host)"
        case .endpoint:
            return "\(flow.request.method) \(endpointPath(of: flow.request.url))"
        case .status:
            return statusClass(of: flow)
        case .app:
            return flow.sourceApp?.groupingKey ?? "(unknown app)"
        case .device:
            return flow.sourceDevice?.groupingKey ?? "(unknown device)"
        case .none:
            return "all"
        }
    }

    /// `2xx` … `5xx`, or `failed` for a transport error, or `pending` in flight.
    public static func statusClass(of flow: Flow) -> String {
        if flow.error != nil { return "failed" }
        guard let status = flow.statusCode else { return "pending" }
        return "\(status / 100)xx"
    }

    /// Path with the query dropped and id-shaped segments collapsed to `{id}`, so a
    /// REST endpoint hit with different ids is one bucket. Deliberately conservative:
    /// only all-digit segments, UUIDs and long hex/base-ish blobs collapse — a
    /// readable path segment stays as written.
    public static func endpointPath(of urlString: String) -> String {
        var path = urlString
        // Strip the scheme+authority by hand (see `URLHost`: building URLComponents per
        // flow is exactly what the perf rules forbid).
        if let schemeEnd = path.range(of: "://") {
            let afterScheme = path[schemeEnd.upperBound...]
            if let slash = afterScheme.firstIndex(of: "/") {
                path = String(afterScheme[slash...])
            } else {
                path = "/"
            }
        }
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[path.startIndex ..< cut])
        }
        guard path.contains("/") else { return path }
        let collapsed = path.split(separator: "/", omittingEmptySubsequences: false).map { segment -> Substring in
            isIDLike(segment) ? "{id}" : segment
        }
        return collapsed.joined(separator: "/")
    }

    private static func isIDLike(_ segment: Substring) -> Bool {
        guard segment.count >= 2 else { return false }
        if segment.allSatisfy(\.isNumber) { return true }
        // A UUID, or a long hex/opaque token (session ids, digests).
        if segment.count >= 16, segment.allSatisfy({ $0.isHexDigit || $0 == "-" }) { return true }
        return false
    }

    /// Mutable per-bucket tally. Percentile samples are kept as raw arrays because a
    /// bucket is bounded by the flow ring, and an exact percentile beats an estimator
    /// nobody can reason about.
    private struct Accumulator {
        var flows = 0
        var errors = 0
        var failed = 0
        var inFlight = 0
        var statusClasses: [String: Int] = [:]
        var ttfb: [Int] = []
        var duration: [Int] = []
        var requestBytes = 0
        var responseBytes = 0
        var sizeUnknownFlows = 0

        mutating func add(_ flow: Flow) {
            flows += 1
            let statusClass = FlowStats.statusClass(of: flow)
            statusClasses[statusClass, default: 0] += 1

            if flow.error != nil {
                errors += 1
                failed += 1
            } else if let status = flow.statusCode {
                if status >= 400 { errors += 1 }
            } else {
                inFlight += 1
            }
            if let ttfbMS = flow.ttfbMS { ttfb.append(ttfbMS) }
            if let durationMS = flow.durationMS { duration.append(durationMS) }

            // A body's size is known from the bytes in hand, or from the recorded wire
            // size when the capture was truncated. Neither is available for a flow
            // whose body has been evicted, so that flow is counted, not guessed at.
            var unknown = false
            switch size(of: flow.request.body, fullBytes: flow.request.fullBodyBytes) {
            case let .known(bytes): requestBytes += bytes
            case .unknown: unknown = true
            }
            if let response = flow.response {
                switch size(of: response.body, fullBytes: response.fullBodyBytes) {
                case let .known(bytes): responseBytes += bytes
                case .unknown: unknown = true
                }
            }
            if unknown { sizeUnknownFlows += 1 }
        }

        private enum Size {
            case known(Int)
            case unknown
        }

        private func size(of body: Data?, fullBytes: Int?) -> Size {
            if let fullBytes { return .known(fullBytes) } // truncated capture: wire size
            if let body { return .known(body.count) }
            return .unknown
        }

        func bucket(key: String) -> Bucket {
            Bucket(
                key: key, flows: flows, errors: errors, failed: failed, inFlight: inFlight,
                statusClasses: statusClasses,
                ttfb: Distribution.from(ttfb), duration: Distribution.from(duration),
                requestBytes: requestBytes, responseBytes: responseBytes,
                sizeUnknownFlows: sizeUnknownFlows
            )
        }
    }
}
