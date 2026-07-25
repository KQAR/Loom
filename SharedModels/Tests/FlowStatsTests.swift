import Testing
import Foundation
import LoomSharedModels

/// `FlowStats` turns "which endpoint is slow / what share of this host's calls fail"
/// into one call instead of a page of summaries plus arithmetic in an agent's head.
/// The numbers are only worth having if they are exact and honest about their sample,
/// which is what this suite pins.
@Suite struct FlowStatsTests {
    private func flow(
        url: String = "https://api.example.com/v1/orders",
        method: String = "GET",
        status: Int? = 200,
        error: String? = nil,
        ttfbMS: Int? = nil,
        durationMS: Int? = nil,
        requestBody: Data? = nil,
        responseBody: Data? = nil,
        responseFullBytes: Int? = nil,
        app: SourceApp? = nil,
        at seconds: TimeInterval = 1_000
    ) -> Flow {
        let startedAt = Date(timeIntervalSince1970: seconds)
        let response = status.map { code in
            var captured = CapturedResponse(statusCode: code, headers: [], body: responseBody)
            captured.fullBodyBytes = responseFullBytes
            return captured
        }
        let outcome: FlowOutcome
        if let error {
            outcome = .failed(FlowError(error), at: startedAt, partialResponse: nil)
        } else if let response {
            outcome = .completed(
                response,
                at: startedAt.addingTimeInterval(Double(durationMS ?? 0) / 1000)
            )
        } else {
            outcome = .pending
        }
        return Flow(
            id: UUID(),
            request: CapturedRequest(method: method, url: url, headers: [], body: requestBody),
            startedAt: startedAt,
            outcome: outcome,
            firstByteAt: ttfbMS.map { startedAt.addingTimeInterval(Double($0) / 1000) },
            sourceApp: app
        )
    }

    // MARK: - Bucketing

    @Test func groupsByHost_biggestFirst_andCapsWithAnOmittedCount() {
        let flows =
            (0 ..< 5).map { _ in flow(url: "https://api.example.com/a") } +
            (0 ..< 3).map { _ in flow(url: "https://cdn.example.com/b") } +
            [flow(url: "https://other.test/c")]

        let stats = FlowStats.compute(flows: flows, grouping: .host, limit: 2)
        #expect(stats.buckets.map(\.key) == ["api.example.com", "cdn.example.com"])
        #expect(stats.buckets.map(\.flows) == [5, 3])
        #expect(stats.bucketsOmitted == 1, "the third host is dropped by the limit — and counted, not hidden")
        #expect(stats.total.flows == 9)
    }

    @Test func endpointGrouping_collapsesIDsAndDropsTheQuery() {
        #expect(FlowStats.endpointPath(of: "https://api.example.com/v1/orders/12345?x=1") == "/v1/orders/{id}")
        #expect(FlowStats.endpointPath(of: "https://api.example.com/v1/orders") == "/v1/orders")
        #expect(FlowStats.endpointPath(of: "https://api.example.com/u/3F2504E0-4F89-11D3-9A0C-0305E82C3301/x")
            == "/u/{id}/x")
        #expect(FlowStats.endpointPath(of: "https://api.example.com") == "/")
        // Conservative on purpose: a readable segment is not an id.
        #expect(FlowStats.endpointPath(of: "https://api.example.com/v1/orders/latest") == "/v1/orders/latest")

        let stats = FlowStats.compute(
            flows: [
                flow(url: "https://api.example.com/v1/orders/1", method: "POST"),
                flow(url: "https://api.example.com/v1/orders/2", method: "POST"),
                flow(url: "https://api.example.com/v1/orders/2", method: "GET"),
            ],
            grouping: .endpoint
        )
        #expect(stats.buckets.map(\.key) == ["POST /v1/orders/{id}", "GET /v1/orders/{id}"])
        #expect(stats.buckets.map(\.flows) == [2, 1], "method is part of the endpoint")
    }

    @Test func groupsByStatusClass_appAndDevice() {
        let app = SourceApp(name: "Safari", bundleID: "com.apple.Safari", pid: 1)
        let byStatus = FlowStats.compute(
            flows: [flow(status: 200), flow(status: 503), flow(status: nil, error: "refused")],
            grouping: .status
        )
        #expect(Set(byStatus.buckets.map(\.key)) == ["2xx", "5xx", "failed"])

        let byApp = FlowStats.compute(flows: [flow(app: app), flow()], grouping: .app)
        #expect(Set(byApp.buckets.map(\.key)) == ["com.apple.Safari", "(unknown app)"])
    }

    @Test func noneGrouping_reportsTotalsWithNoBuckets() {
        let stats = FlowStats.compute(flows: [flow(), flow(status: 500)], grouping: .none)
        #expect(stats.buckets.isEmpty)
        #expect(stats.total.flows == 2)
        #expect(stats.total.errors == 1)
    }

    // MARK: - Rates and distributions

    @Test func errorRate_countsTransportFailuresAnd4xx5xx_butExcludesInFlight() {
        let stats = FlowStats.compute(
            flows: [
                flow(status: 200), flow(status: 200),
                flow(status: 404), flow(status: nil, error: "connection refused"),
                flow(status: nil), // in flight — neither good nor bad news yet
            ],
            grouping: .none
        )
        #expect(stats.total.errors == 2)
        #expect(stats.total.failed == 1, "the transport failure alone")
        #expect(stats.total.inFlight == 1)
        // 2 errors out of the 4 settled exchanges, not out of all 5.
        #expect(stats.total.errorRate == 0.5)
    }

    @Test func percentilesAreExactSamples_neverInterpolated() {
        let flows = (1 ... 10).map { flow(ttfbMS: $0 * 10, durationMS: $0 * 100) }
        let ttfb = try! #require(FlowStats.compute(flows: flows, grouping: .none).total.ttfb)
        #expect(ttfb.samples == 10)
        #expect(ttfb.p50 == 50)
        #expect(ttfb.p95 == 100)
        #expect(ttfb.max == 100)
        // Every reported number is a latency some request actually had.
        #expect([10, 20, 30, 40, 50, 60, 70, 80, 90, 100].contains(ttfb.p50))
    }

    @Test func aBucketWithNoTimingReportsNoDistribution_ratherThanZero() {
        let stats = FlowStats.compute(flows: [flow(status: nil)], grouping: .none)
        #expect(stats.total.ttfb == nil, "a pending flow has no TTFB — reporting 0 ms would be a lie")
        #expect(stats.total.duration == nil)
    }

    @Test func emptyCapture_isAllZeroes_notACrash() {
        let stats = FlowStats.compute(flows: [], grouping: .host)
        #expect(stats.total.flows == 0)
        #expect(stats.total.errorRate == 0)
        #expect(stats.buckets.isEmpty)
        #expect(stats.slowest.isEmpty)
        #expect(stats.earliest == nil)
    }

    // MARK: - Bytes, and being honest about them

    @Test func byteTotals_useTheWireSizeWhenTheCaptureWasTruncated() {
        let stats = FlowStats.compute(
            flows: [
                flow(requestBody: Data(count: 100), responseBody: Data(count: 200)),
                // A truncated capture: 50 bytes kept, 9000 actually flowed.
                flow(responseBody: Data(count: 50), responseFullBytes: 9_000),
            ],
            grouping: .none
        )
        #expect(stats.total.requestBytes == 100)
        #expect(stats.total.responseBytes == 9_200, "the truncated flow contributes its wire size")
        #expect(stats.total.sizeUnknownFlows == 0)
    }

    /// `Content-Length` is what makes byte totals survive body eviction — it is
    /// metadata, so it is still there when the payload isn't.
    @Test func anEvictedBodyStillCountsWhenItsLengthWasDeclared() {
        let declared = Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "https://api.example.com/x", headers: []),
            startedAt: Date(timeIntervalSince1970: 1),
            outcome: .completed(
                CapturedResponse(
                    statusCode: 200,
                    headers: [HeaderPair(name: "Content-Length", value: "4096")],
                    body: Data(count: 4096)
                ),
                at: Date(timeIntervalSince1970: 1)
            )
        ).strippingBodies()

        let stats = FlowStats.compute(flows: [declared], grouping: .none)
        #expect(stats.total.responseBytes == 4096)
        #expect(stats.total.sizeUnknownFlows == 0)
    }

    @Test func bodylessMessagesAreZero_notUnknown() {
        // A GET with no framing headers has no body at all: 0 is the truth, not a guess.
        #expect(BodySize.ofRequest(CapturedRequest(method: "GET", url: "https://x/", headers: [])) == .known(0))
        // A POST with neither bytes nor a declared length (a chunked upload, body gone)
        // genuinely isn't known.
        #expect(BodySize.ofRequest(CapturedRequest(method: "POST", url: "https://x/", headers: [])) == .unknown)
        // 204 and a HEAD response carry no body by framing.
        #expect(BodySize.ofResponse(CapturedResponse(statusCode: 204, headers: []), requestMethod: "GET") == .known(0))
        #expect(BodySize.ofResponse(CapturedResponse(statusCode: 200, headers: []), requestMethod: "HEAD") == .known(0))
        #expect(BodySize.ofResponse(CapturedResponse(statusCode: 200, headers: []), requestMethod: "GET") == .unknown,
                "a 200 whose body is gone and whose length was never declared is unknown")
        // A chunked GET response body that's gone is unknown, framing notwithstanding.
        #expect(BodySize.ofRequest(CapturedRequest(
            method: "GET", url: "https://x/", headers: [HeaderPair(name: "Transfer-Encoding", value: "chunked")]
        )) == .unknown)
    }

    @Test func anEvictedBodyIsCountedAsUnknown_notAsZero() {
        // What the ring holds once the byte budget slims a flow whose length was never
        // declared (the forwarder drops Content-Length on a decompressed response):
        // no body, no wire size, nothing to infer from.
        let slimmed = flow(responseBody: Data(count: 500)).strippingBodies()
        let stats = FlowStats.compute(flows: [slimmed], grouping: .none)
        #expect(stats.total.responseBytes == 0)
        #expect(stats.total.sizeUnknownFlows == 1,
                "byte totals must read as a floor, not as a total that happens to be wrong")
    }

    // MARK: - Slowest

    @Test func slowestNamesTheExchangesToFollowUpOn() {
        let quick = flow(url: "https://api.example.com/fast", ttfbMS: 10, durationMS: 20)
        let slow = flow(url: "https://api.example.com/slow", ttfbMS: 900, durationMS: 1_000)
        let middling = flow(url: "https://api.example.com/mid", ttfbMS: 300, durationMS: 400)

        let stats = FlowStats.compute(flows: [quick, slow, middling], grouping: .host, slowest: 2)
        #expect(stats.slowest.map(\.url) == [
            "https://api.example.com/slow", "https://api.example.com/mid",
        ])
        #expect(stats.slowest.first?.id == slow.id, "carries the id, so the follow-up is one call away")
        #expect(stats.slowest.first?.ttfbMS == 900)
    }

    @Test func bucketOrderIsStableForIdenticalCounts() {
        let flows = [flow(url: "https://b.test/x"), flow(url: "https://a.test/x")]
        let first = FlowStats.compute(flows: flows, grouping: .host).buckets.map(\.key)
        let second = FlowStats.compute(flows: flows.reversed(), grouping: .host).buckets.map(\.key)
        #expect(first == second, "an agent diffing two runs must not see phantom reordering")
    }
}
