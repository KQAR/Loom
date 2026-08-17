import Testing
import Foundation
import LoomSharedModels

/// A HAR is how a capture crosses machines: a colleague's DevTools export, a CI
/// artifact, a bug report. Importing turns one into flows that can be inspected,
/// diffed and replayed like live traffic — which only works if the parser survives
/// what real tools actually write (missing timings, absent bodies, base64 content,
/// timestamps with or without fractional seconds) and is loud about what it couldn't
/// use.
@Suite struct HARImportTests {
    private func har(entries: String) -> Data {
        Data("""
        {"log":{"version":"1.2","creator":{"name":"Test","version":"1"},"entries":[\(entries)]}}
        """.utf8)
    }

    private let simpleEntry = """
    {"startedDateTime":"2026-07-20T10:00:00.000Z","time":150,
     "request":{"method":"POST","url":"https://api.example.com/v1/orders?x=1",
                "headers":[{"name":"Authorization","value":"Bearer abc"}],
                "postData":{"mimeType":"application/json","text":"{\\"a\\":1}"}},
     "response":{"status":201,"httpVersion":"HTTP/2","headers":[{"name":"Content-Type","value":"application/json"}],
                 "content":{"size":11,"mimeType":"application/json","text":"{\\"ok\\":true}"}},
     "timings":{"send":0,"wait":100,"receive":50}}
    """

    @Test func importsAnEntryWithEverythingItNeeds() throws {
        let result = try HARImport.decode(har(entries: simpleEntry), label: "colleague.har")
        #expect(result.skipped == 0)
        let flow = try #require(result.flows.first)

        #expect(flow.request.method == "POST")
        #expect(flow.request.url == "https://api.example.com/v1/orders?x=1")
        #expect(flow.request.headers.value(named: "authorization") == "Bearer abc")
        #expect(flow.request.body == Data(#"{"a":1}"#.utf8))
        #expect(flow.statusCode == 201)
        #expect(flow.response?.httpVersion == "HTTP/2")
        #expect(flow.response?.body == Data(#"{"ok":true}"#.utf8))
        #expect(flow.importedFrom == "colleague.har", "an imported flow must say so")
        // Timings: wait is TTFB, `time` the whole exchange.
        #expect(flow.ttfbMS == 100)
        #expect(flow.durationMS == 150)
    }

    @Test func decodesBase64Bodies_soABinaryRoundTripSurvives() throws {
        let payload = Data([0x89, 0x50, 0x4E, 0x47, 0xFF])
        let entry = """
        {"startedDateTime":"2026-07-20T10:00:00Z","time":10,
         "request":{"method":"PUT","url":"https://api.example.com/blob","headers":[],
                    "postData":{"mimeType":"application/octet-stream","text":"\(payload.base64EncodedString())","_encoding":"base64"}},
         "response":{"status":200,"headers":[],
                     "content":{"size":5,"mimeType":"image/png","text":"\(payload.base64EncodedString())","encoding":"base64"}}}
        """
        let flow = try #require(try HARImport.decode(har(entries: entry), label: "x.har").flows.first)
        #expect(flow.request.body == payload)
        #expect(flow.response?.body == payload)
    }

    @Test func toleratesMissingTimingsAndBodies() throws {
        let entry = """
        {"startedDateTime":"2026-07-20T10:00:00Z",
         "request":{"method":"GET","url":"https://api.example.com/ping","headers":[]},
         "response":{"status":204,"headers":[]}}
        """
        let flow = try #require(try HARImport.decode(har(entries: entry), label: "x.har").flows.first)
        #expect(flow.statusCode == 204)
        #expect(flow.request.body == nil)
        #expect(flow.ttfbMS == nil, "no timing recorded is not a timing of zero")
    }

    /// HAR writes -1 for "not measured". Treating that as a duration would put
    /// `completedAt` before `startedAt` and poison every derived figure.
    @Test func notMeasuredTimingsAreNotNegativeDurations() throws {
        let entry = """
        {"startedDateTime":"2026-07-20T10:00:00Z","time":-1,
         "request":{"method":"GET","url":"https://api.example.com/ping","headers":[]},
         "response":{"status":200,"headers":[]},
         "timings":{"send":-1,"wait":-1,"receive":-1}}
        """
        let flow = try #require(try HARImport.decode(har(entries: entry), label: "x.har").flows.first)
        #expect(flow.ttfbMS == nil)
        #expect((flow.durationMS ?? 0) >= 0)
    }

    @Test func aBadEntryIsSkippedAndCounted_notDroppedSilently() throws {
        let bad = """
        {"startedDateTime":"2026-07-20T10:00:00Z","request":{"url":"https://api.example.com/x","headers":[]},
         "response":{"status":200,"headers":[]}}
        """
        let result = try HARImport.decode(har(entries: "\(simpleEntry),\(bad)"), label: "mixed.har")
        #expect(result.flows.count == 1, "the good entry still imports")
        #expect(result.skipped == 1)
        #expect(result.reasons.count == 1)
        #expect(result.reasons.first?.contains("method") == true)
    }

    @Test func aFailedExchangeStaysAFailure() throws {
        let entry = """
        {"startedDateTime":"2026-07-20T10:00:00Z","time":20,
         "request":{"method":"GET","url":"https://api.example.com/x","headers":[]},
         "response":{"status":0,"headers":[]},
         "_error":"connection refused"}
        """
        let flow = try #require(try HARImport.decode(har(entries: entry), label: "x.har").flows.first)
        #expect(flow.error == "connection refused")
        #expect(flow.statusCode == nil, "inventing a status for a failed exchange would be a lie")
    }

    @Test func entriesComeBackOldestFirst() throws {
        let older = simpleEntry.replacingOccurrences(of: "2026-07-20T10:00:00.000Z", with: "2026-07-20T09:00:00.000Z")
        let result = try HARImport.decode(har(entries: "\(simpleEntry),\(older)"), label: "x.har")
        #expect(result.flows.map(\.startedAt) == result.flows.map(\.startedAt).sorted())
    }

    @Test func rejectsNonJSONAndNonHAR() {
        #expect(throws: HARImport.Failure.notJSON) { try HARImport.decode(Data("not json".utf8), label: "x") }
        #expect(throws: HARImport.Failure.notHAR) {
            try HARImport.decode(Data(#"{"hello":"world"}"#.utf8), label: "x")
        }
    }

    /// The round trip that matters: what Loom exports, Loom can read back.
    @Test func loomsOwnExportImportsBack() throws {
        let original = Flow(
            id: UUID(),
            request: CapturedRequest(
                method: "POST", url: "https://api.example.com/v1/orders",
                headers: [HeaderPair(name: "X-Trace", value: "t-1")],
                body: Data(#"{"id":7}"#.utf8)
            ),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            outcome: .completed(
                CapturedResponse(statusCode: 500, headers: [], body: Data("boom".utf8)),
                at: Date(timeIntervalSince1970: 1_700_000_000.4)
            ),
            firstByteAt: Date(timeIntervalSince1970: 1_700_000_000.25)
        )
        let exported = HARExport.encode([original], appVersion: "9.9")
        let flow = try #require(try HARImport.decode(exported, label: "loom-export.har").flows.first)

        #expect(flow.request.method == original.request.method)
        #expect(flow.request.url == original.request.url)
        #expect(flow.request.headers.value(named: "x-trace") == "t-1")
        #expect(flow.request.body == original.request.body)
        #expect(flow.statusCode == 500)
        #expect(flow.response?.body == Data("boom".utf8))
        #expect(flow.ttfbMS == original.ttfbMS)
        #expect(flow.id != original.id, "a fresh id — the file's ids may collide with the store's")
    }

    @Test func tunnelDiagnosticAndFailureCodeSurviveLoomHAR() throws {
        let original = Flow(
            request: CapturedRequest(
                method: "CONNECT", url: "https://api.example.com:443", headers: []
            ),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            outcome: .failed(
                FlowError(
                    "Client rejected Loom's certificate",
                    code: .clientCertificateRejected,
                    detail: "certificate_unknown"
                ),
                at: Date(timeIntervalSince1970: 1_700_000_000.02),
                partialResponse: nil
            ),
            tunnelDiagnostic: Flow.TunnelDiagnostic(
                host: "api.example.com",
                port: 443,
                reason: .clientHandshakeFailed,
                detail: "certificate_unknown"
            )
        )

        let exported = HARExport.encode([original], appVersion: "9.9")
        let imported = try #require(
            try HARImport.decode(exported, label: "loom.har").flows.first
        )
        #expect(imported.recordKind == .tunnel)
        #expect(imported.tunnelDiagnostic == original.tunnelDiagnostic)
        #expect(imported.flowError?.code == .clientCertificateRejected)
        #expect(imported.flowError?.detail == "certificate_unknown")
    }

    @Test func failedFlowKeepsItsPartialResponseAndStructuredError() throws {
        let original = Flow(
            request: CapturedRequest(
                method: "GET", url: "https://api.example.com/v1", headers: []
            ),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            outcome: .failed(
                FlowError(
                    "stream ended",
                    code: .clientHandshakeFailed,
                    detail: "underlying detail"
                ),
                at: Date(timeIntervalSince1970: 1_700_000_001),
                partialResponse: CapturedResponse(
                    statusCode: 502,
                    headers: [HeaderPair(name: "X-Partial", value: "yes")],
                    body: Data("partial".utf8)
                )
            )
        )

        let imported = try #require(try HARImport.decode(
            HARExport.encode([original], appVersion: "9.9"),
            label: "loom.har"
        ).flows.first)
        #expect(imported.error == "stream ended")
        #expect(imported.flowError?.code == .clientHandshakeFailed)
        #expect(imported.flowError?.detail == "underlying detail")
        #expect(imported.response?.statusCode == 502)
        #expect(imported.response?.body == Data("partial".utf8))
    }

    // MARK: - A capped body must not come back looking whole

    /// `HARExport` writes the wire size and marks a capped body with
    /// `_bodyTruncated`; import read neither, so every imported flow came back with
    /// `fullBodyBytes == nil` — which `isBodyTruncated` reads as "this is the whole
    /// payload".
    ///
    /// The consequence is a wrong answer rather than a thin one:
    /// `FlowComparison.compareBodies` takes both sides' `fullBodyBytes` exactly so
    /// two bodies capped at the same length report `.tailNotCaptured` instead of
    /// identical. Dropped on import, `diff_flows` over a re-imported capture says
    /// "no difference" about two bodies that differ.
    @Test func loomsOwnTruncationSurvivesTheRoundTrip() throws {
        let original = Flow(
            request: CapturedRequest(
                method: "POST", url: "https://api.example.com/upload", headers: [],
                body: Data(repeating: 0x41, count: 16), fullBodyBytes: 4096
            ),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            outcome: .completed(
                CapturedResponse(
                    statusCode: 200, headers: [],
                    body: Data(repeating: 0x42, count: 16), fullBodyBytes: 900_000
                ),
                at: Date(timeIntervalSince1970: 1_700_000_001)
            )
        )
        let exported = HARExport.encode([original], appVersion: "9.9")
        let flow = try #require(try HARImport.decode(exported, label: "loom.har").flows.first)

        #expect(flow.request.fullBodyBytes == 4096)
        #expect(flow.request.isBodyTruncated)
        #expect(flow.response?.fullBodyBytes == 900_000)
        #expect(flow.response?.isBodyTruncated == true)
    }

    /// The failure the field exists to prevent, end to end: two exchanges whose
    /// captured prefixes are identical and whose full bodies are not.
    @Test func twoTruncatedImportsDoNotCompareIdentical() throws {
        func flow(wireBytes: Int) -> Flow {
            Flow(
                request: CapturedRequest(method: "GET", url: "https://api.example.com/x", headers: []),
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                outcome: .completed(
                    CapturedResponse(
                        statusCode: 200, headers: [],
                        body: Data("the same first sixteen".utf8), fullBodyBytes: wireBytes
                    ),
                    at: Date(timeIntervalSince1970: 1_700_000_001)
                )
            )
        }
        let exported = HARExport.encode([flow(wireBytes: 5000), flow(wireBytes: 9000)], appVersion: "9.9")
        let imported = try HARImport.decode(exported, label: "loom.har").flows
        #expect(imported.count == 2)

        let comparison = FlowComparison.compare(base: imported[0], compared: imported[1])
        #expect(comparison.isPartial, "a capped body can never qualify as an identical one")
    }

    /// The foreign-HAR case: DevTools omits `content.text` for large or unavailable
    /// payloads and still reports the size. An empty prefix is a prefix, and saying
    /// so is what keeps two such entries from comparing equal.
    @Test func aDeclaredSizeWithNoBodyIsRecordedAsTheWireSize() throws {
        let entry = """
        {"startedDateTime":"2026-07-20T10:00:00.000Z","time":10,
         "request":{"method":"GET","url":"https://api.example.com/big","headers":[]},
         "response":{"status":200,"httpVersion":"HTTP/1.1","headers":[],
                     "content":{"size":1048576,"mimeType":"video/mp4"}}}
        """
        let flow = try #require(try HARImport.decode(har(entries: entry), label: "devtools.har").flows.first)
        #expect(flow.response?.fullBodyBytes == 1_048_576)
        #expect(flow.response?.body == nil)
    }

    /// The inference deliberately **not** made. A foreign exporter's size and its
    /// body length differ for ordinary reasons — compression, transfer encodings, an
    /// exporter counting characters — so a mismatch alone must not mark an exchange
    /// partial. A false "truncated" is cheaper than a false "complete" and still a
    /// wrong claim on the surface whose job is to say when a comparison can't be
    /// trusted.
    @Test func aSizeDisagreeingWithAPresentBodyIsNotTreatedAsTruncation() throws {
        let entry = """
        {"startedDateTime":"2026-07-20T10:00:00.000Z","time":10,
         "request":{"method":"GET","url":"https://api.example.com/z","headers":[]},
         "response":{"status":200,"httpVersion":"HTTP/1.1","headers":[],
                     "content":{"size":99999,"mimeType":"application/json","text":"{\\"ok\\":true}"}}}
        """
        let flow = try #require(try HARImport.decode(har(entries: entry), label: "devtools.har").flows.first)
        #expect(flow.response?.body == Data(#"{"ok":true}"#.utf8))
        #expect(flow.response?.fullBodyBytes == nil)
        #expect(flow.response?.isBodyTruncated == false)
    }
}
