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

    private func exchange(
        requestHeaders: [HeaderPair] = [],
        responseHeaders: [HeaderPair] = [],
        requestBody: Data? = nil,
        responseBody: Data? = nil
    ) -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(
                method: "POST", url: "https://api.example.com/v1/orders",
                headers: requestHeaders, body: requestBody
            ),
            startedAt: Date(timeIntervalSince1970: 1_000),
            outcome: .completed(
                CapturedResponse(statusCode: 200, headers: responseHeaders, body: responseBody),
                at: Date(timeIntervalSince1970: 1_001)
            )
        )
    }

    @Test func headerContains_matchesNameOrValue_onEitherSide() {
        let flow = exchange(
            requestHeaders: [HeaderPair(name: "Authorization", value: "Bearer eyJhbGci")],
            responseHeaders: [HeaderPair(name: "Set-Cookie", value: "sid=abc; HttpOnly")]
        )
        #expect(FlowQuery(headerContains: "authorization").matches(flow), "by name, case-insensitively")
        #expect(FlowQuery(headerContains: "eyJhbGci").matches(flow), "by value")
        #expect(FlowQuery(headerContains: "set-cookie").matches(flow), "response headers count too")
        #expect(!FlowQuery(headerContains: "x-trace-id").matches(flow))
    }

    @Test func headerContains_withAColon_bindsNameAndValueToTheSameHeader() {
        let flow = exchange(
            requestHeaders: [HeaderPair(name: "X-Env", value: "production")],
            responseHeaders: [HeaderPair(name: "X-Cache", value: "staging-hit")]
        )
        #expect(FlowQuery(headerContains: "x-env: production").matches(flow))
        #expect(!FlowQuery(headerContains: "x-env: staging").matches(flow),
                "`staging` appears in another header — that must not satisfy the pair")
        #expect(FlowQuery(headerContains: "x-env:").matches(flow), "an empty value half means `has this header`")
    }

    @Test func bodyContains_searchesBothSides_caseInsensitively() {
        let flow = exchange(
            requestBody: Data(#"{"orderId":"AB-9931"}"#.utf8),
            responseBody: Data(#"{"error":"INSUFFICIENT_FUNDS"}"#.utf8)
        )
        #expect(FlowQuery(bodyContains: "ab-9931").matches(flow), "request body, folded case")
        #expect(FlowQuery(bodyContains: "insufficient_funds").matches(flow), "response body")
        #expect(!FlowQuery(bodyContains: "AB-9932").matches(flow))
        #expect(!FlowQuery(bodyContains: "anything").matches(exchange()), "no body can't match")
    }

    @Test func bodyContains_worksOnNonUTF8Bytes_andNonASCIINeedles() {
        // A PNG header followed by a stray 0xFF — not decodable as UTF-8 at all.
        var binary = Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFE])
        binary.append(Data("MARKER".utf8))
        #expect(FlowQuery(bodyContains: "marker").matches(exchange(responseBody: binary)),
                "a binary payload is still searchable")
        #expect(FlowQuery(bodyContains: "订单已创建").matches(exchange(responseBody: Data("状态:订单已创建".utf8))),
                "a non-ASCII needle matches byte-for-byte")
    }

    @Test func needsBodies_isOnlySetByTheBodyPredicate() {
        #expect(!FlowQuery(host: "api.example.com").needsBodies)
        #expect(!FlowQuery(headerContains: "authorization").needsBodies, "headers are always in memory")
        #expect(FlowQuery(bodyContains: "x").needsBodies)
        #expect(!FlowQuery(bodyContains: "").needsBodies, "an empty needle constrains nothing")
    }

    /// The split the store relies on: metadata predicates must not need a body, and
    /// a body predicate must not be silently satisfied by metadata alone.
    @Test func metadataAndBodyPredicates_areEvaluatedSeparately() {
        let flow = exchange(requestHeaders: [HeaderPair(name: "X-Env", value: "staging")],
                            responseBody: Data("payload".utf8))
        let query = FlowQuery(headerContains: "x-env: staging", bodyContains: "payload")
        #expect(query.matchesMetadata(flow), "the header half stands on its own")
        #expect(query.matchesBodies(flow))
        // A body-free copy (as the ring holds it once slimmed) fails the body half,
        // which is exactly why the store hydrates a candidate before asking.
        #expect(!query.matchesBodies(flow.strippingBodies()))
        #expect(FlowQuery(headerContains: "x-env: staging").matchesBodies(flow.strippingBodies()),
                "no body predicate → trivially true, so callers can apply it unconditionally")
    }

    @Test func predicatesAND_together() {
        let query = FlowQuery(host: "api.example.com", methods: ["POST"], onlyErrors: true)
        #expect(query.matches(flow(method: "POST", status: 500)))
        #expect(!query.matches(flow(method: "GET", status: 500)), "wrong method")
        #expect(!query.matches(flow(method: "POST", status: 200)), "not an error")
        #expect(!query.matches(flow(method: "POST", url: "https://other.test/x", status: 500)), "wrong host")
    }
}
