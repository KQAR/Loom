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
}
