import Testing
import Foundation
import LoomSharedModels

/// `FlowQuery` is what makes "find the exchange I care about" answerable without
/// dumping the capture into an agent's context. Its predicates are pure, so they
/// are pinned here (the store-level "filter before limit" ordering is covered in
/// `FlowStoreQueryTests`).
@Suite struct FlowQueryTests {
    private func flow(
        method: String = "GET",
        url: String = "https://api.example.com/v1/orders",
        status: Int? = 200,
        error: String? = nil,
        startedAt: Date = Date(timeIntervalSince1970: 1_000),
        device: SourceDevice? = nil,
        app: SourceApp? = nil
    ) -> Flow {
        let outcome: FlowOutcome
        if let error {
            outcome = .failed(FlowError(error), at: startedAt, partialResponse: nil)
        } else if let status {
            outcome = .completed(CapturedResponse(statusCode: status, headers: []), at: startedAt)
        } else {
            outcome = .pending
        }
        return Flow(
            id: UUID(),
            request: CapturedRequest(method: method, url: url, headers: []),
            startedAt: startedAt, outcome: outcome, sourceApp: app, sourceDevice: device
        )
    }

    @Test func empty_matchesEverything() {
        #expect(FlowQuery.all.isEmpty)
        #expect(FlowQuery.all.matches(flow()))
    }

    @Test func host_exactAndGlob() {
        #expect(FlowQuery(host: "api.example.com").matches(flow()))
        #expect(FlowQuery(host: "*.example.com").matches(flow()))
        #expect(!FlowQuery(host: "other.example.com").matches(flow()))
        #expect(!FlowQuery(host: "*.example.org").matches(flow()))
    }

    @Test func method_isCaseInsensitive_andAcceptsSeveral() {
        #expect(FlowQuery(methods: ["get"]).matches(flow(method: "GET")))
        #expect(FlowQuery(methods: ["POST", "PUT"]).matches(flow(method: "PUT")))
        #expect(!FlowQuery(methods: ["POST"]).matches(flow(method: "GET")))
    }

    @Test func urlContains_isCaseInsensitiveSubstring() {
        #expect(FlowQuery(urlContains: "/v1/ORDERS").matches(flow()))
        #expect(FlowQuery(urlContains: "orders").matches(flow()))
        #expect(!FlowQuery(urlContains: "/v2/").matches(flow()))
    }

    @Test func statusBounds() {
        #expect(FlowQuery(statusMin: 500, statusMax: 599).matches(flow(status: 503)))
        #expect(!FlowQuery(statusMin: 500, statusMax: 599).matches(flow(status: 404)))
        // An exact status is expressed as an equal pair.
        #expect(FlowQuery(statusMin: 404, statusMax: 404).matches(flow(status: 404)))
        // A flow with no status can't satisfy a status bound.
        #expect(!FlowQuery(statusMin: 200, statusMax: 299).matches(flow(status: nil)))
    }

    @Test func onlyErrors_coversTransportErrorsAnd4xx5xx_butNotInFlight() {
        #expect(FlowQuery(onlyErrors: true).matches(flow(status: 500)))
        #expect(FlowQuery(onlyErrors: true).matches(flow(status: 404)))
        #expect(FlowQuery(onlyErrors: true).matches(flow(status: nil, error: "connection refused")))
        #expect(!FlowQuery(onlyErrors: true).matches(flow(status: 200)))
        #expect(!FlowQuery(onlyErrors: true).matches(flow(status: nil)),
                "a still-pending flow is not a failure")
    }

    @Test func since_isInclusive() {
        let cutoff = Date(timeIntervalSince1970: 1_000)
        #expect(FlowQuery(since: cutoff).matches(flow(startedAt: cutoff)))
        #expect(FlowQuery(since: cutoff).matches(flow(startedAt: cutoff.addingTimeInterval(1))))
        #expect(!FlowQuery(since: cutoff).matches(flow(startedAt: cutoff.addingTimeInterval(-1))))
    }

    @Test func deviceAndSourceApp() {
        let device = SourceDevice(ip: "192.168.1.9", kind: .lan, platform: "iOS", client: nil)
        let app = SourceApp(name: "Safari", bundleID: "com.apple.Safari", pid: 42)
        #expect(FlowQuery(deviceIP: "192.168.1.9").matches(flow(device: device)))
        #expect(!FlowQuery(deviceIP: "192.168.1.10").matches(flow(device: device)))
        // By bundle id or by display name, either way.
        #expect(FlowQuery(sourceApp: "com.apple.safari").matches(flow(app: app)))
        #expect(FlowQuery(sourceApp: "Safari").matches(flow(app: app)))
        #expect(!FlowQuery(sourceApp: "Chrome").matches(flow(app: app)))
    }

    @Test func predicatesAND_together() {
        let query = FlowQuery(host: "api.example.com", methods: ["POST"], onlyErrors: true)
        #expect(query.matches(flow(method: "POST", status: 500)))
        #expect(!query.matches(flow(method: "GET", status: 500)), "wrong method")
        #expect(!query.matches(flow(method: "POST", status: 200)), "not an error")
        #expect(!query.matches(flow(method: "POST", url: "https://other.test/x", status: 500)), "wrong host")
    }
}
