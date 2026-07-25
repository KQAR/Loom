import Testing
import Foundation
import LoomSharedModels

/// A capture is full of credentials by construction, and HAR export is the one place
/// it is meant to leave the machine. Redaction is what makes an export attachable —
/// and the property that makes it trustworthy is that it *replaces* rather than
/// deletes: a reader has to be able to tell "there was a token here" from "there was
/// no token", and everything that makes an exchange diagnosable has to survive.
@Suite struct FlowRedactionTests {
    private func flow(
        url: String = "https://api.example.com/v1/orders",
        requestHeaders: [HeaderPair] = [],
        responseHeaders: [HeaderPair] = [],
        requestBody: Data? = nil,
        responseBody: Data? = nil
    ) -> Flow {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        return Flow(
            id: UUID(),
            request: CapturedRequest(method: "POST", url: url, headers: requestHeaders, body: requestBody),
            startedAt: startedAt,
            outcome: .completed(
                CapturedResponse(statusCode: 200, headers: responseHeaders, body: responseBody),
                at: startedAt.addingTimeInterval(0.2)
            ),
            firstByteAt: startedAt.addingTimeInterval(0.1),
            sourceApp: SourceApp(name: "MyApp", bundleID: "com.example.MyApp", pid: 1),
            appliedRules: [AppliedRule(id: UUID(), name: "mock orders")]
        )
    }

    @Test func credentialHeadersLoseTheirValues_butKeepTheirNames() {
        let redacted = FlowRedaction().apply(to: flow(
            requestHeaders: [
                HeaderPair(name: "Authorization", value: "Bearer eyJhbGciOi"),
                HeaderPair(name: "Cookie", value: "sid=abc"),
                HeaderPair(name: "X-Trace", value: "t-1"),
            ],
            responseHeaders: [HeaderPair(name: "Set-Cookie", value: "sid=def; HttpOnly")]
        ))

        #expect(redacted.request.headers.value(named: "authorization") == FlowRedaction.placeholder)
        #expect(redacted.request.headers.value(named: "cookie") == FlowRedaction.placeholder)
        #expect(redacted.response?.headers.value(named: "set-cookie") == FlowRedaction.placeholder)
        #expect(redacted.request.headers.contains(named: "authorization"),
                "the header must remain — a deleted one reads as \"no auth was sent\"")
        #expect(redacted.request.headers.value(named: "x-trace") == "t-1", "non-secrets are untouched")
    }

    @Test func tokenQueryParametersAreScrubbed_theRestOfTheURLIsNot() {
        let redacted = FlowRedaction().apply(to: flow(
            url: "https://api.example.com/v1/orders?access_token=secret&page=2&SIG=deadbeef"
        ))
        let url = redacted.request.url
        #expect(!url.contains("secret"))
        #expect(!url.contains("deadbeef"))
        #expect(url.contains("page=2"), "an ordinary parameter survives")
        #expect(url.contains("access_token="))
        #expect(url.hasPrefix("https://api.example.com/v1/orders?"), "path and host are untouched")
    }

    @Test func aURLWithNoQueryIsLeftExactlyAsCaptured() {
        let original = flow(url: "https://api.example.com/v1/orders")
        #expect(FlowRedaction().apply(to: original).request.url == original.request.url)
    }

    @Test func droppingBodiesKeepsTheirSizes() {
        let redacted = FlowRedaction(dropBodies: true).apply(to: flow(
            requestBody: Data(count: 120), responseBody: Data(count: 4_096)
        ))
        #expect(redacted.request.body == nil)
        #expect(redacted.request.fullBodyBytes == 120, "the size is the evidence that a payload existed")
        #expect(redacted.response?.body == nil)
        #expect(redacted.response?.fullBodyBytes == 4_096)
    }

    @Test func bodiesAreKeptUnlessAskedFor() {
        let redacted = FlowRedaction().apply(to: flow(responseBody: Data("hello".utf8)))
        #expect(redacted.response?.body == Data("hello".utf8))
    }

    @Test func everythingDiagnosticSurvivesRedaction() {
        let original = flow(
            requestHeaders: [HeaderPair(name: "Authorization", value: "Bearer x")],
            responseBody: Data("body".utf8)
        )
        let redacted = FlowRedaction(dropBodies: true).apply(to: original)
        #expect(redacted.id == original.id)
        #expect(redacted.statusCode == 200)
        #expect(redacted.ttfbMS == original.ttfbMS)
        #expect(redacted.durationMS == original.durationMS)
        #expect(redacted.sourceApp == original.sourceApp)
        #expect(redacted.appliedRules?.map(\.name) == ["mock orders"])
    }

    @Test func extraHeaderNamesCanBeAdded() {
        let redaction = FlowRedaction(headerNames: FlowRedaction.defaultHeaderNames + ["x-internal-id"])
        let redacted = redaction.apply(to: flow(
            requestHeaders: [HeaderPair(name: "X-Internal-Id", value: "u-42")]
        ))
        #expect(redacted.request.headers.value(named: "x-internal-id") == FlowRedaction.placeholder)
    }

    @Test func aPendingFlowRedactsWithoutInventingAResponse() {
        let pending = Flow(
            id: UUID(),
            request: CapturedRequest(
                method: "GET", url: "https://api.example.com/x?token=abc",
                headers: [HeaderPair(name: "Authorization", value: "Bearer x")]
            ),
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let redacted = FlowRedaction(dropBodies: true).apply(to: pending)
        #expect(redacted.outcome == .pending)
        #expect(redacted.request.headers.value(named: "authorization") == FlowRedaction.placeholder)
        #expect(!redacted.request.url.contains("abc"))
    }

    /// A redacted export must still be a valid HAR, and must not carry the secret in
    /// some other field the encoder writes (query strings are emitted separately from
    /// the URL).
    @Test func aRedactedFlowExportsWithNoSecretsAnywhereInTheHAR() throws {
        let redacted = FlowRedaction(dropBodies: true).apply(to: flow(
            url: "https://api.example.com/v1/orders?access_token=SUPERSECRET",
            requestHeaders: [HeaderPair(name: "Authorization", value: "Bearer TOPSECRET")],
            responseBody: Data("PAYLOAD".utf8)
        ))
        let har = HARExport.encode([redacted], appVersion: "9.9")
        let text = try #require(String(data: har, encoding: .utf8))
        #expect(!text.contains("SUPERSECRET"))
        #expect(!text.contains("TOPSECRET"))
        #expect(!text.contains("PAYLOAD"))
        #expect(text.contains(FlowRedaction.placeholder))
        // …and it still parses as a HAR.
        #expect(try HARImport.decode(har, label: "x.har").flows.count == 1)
    }
}
