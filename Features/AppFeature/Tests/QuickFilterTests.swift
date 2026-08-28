import ComposableArchitecture
import Foundation
import LoomSharedModels
import Testing

@testable import AppFeature

/// The request list's quick filters: what each chip classifies, and that a set of
/// them composes the way the sidebar's selection does.
@Suite struct QuickFilterTests {
    private func flow(
        url: String = "https://a.test/1",
        version: String? = "HTTP/1.1",
        status: Int? = 200,
        contentType: String? = "application/json"
    ) -> Flow {
        var request = CapturedRequest(method: "GET", url: url, headers: [])
        request.httpVersion = version
        let headers = contentType.map { [HeaderPair(name: "Content-Type", value: $0)] } ?? []
        return Flow(
            id: UUID(),
            request: request,
            startedAt: Date(timeIntervalSince1970: 1),
            outcome: status.map {
                .completed(CapturedResponse(statusCode: $0, headers: headers), at: Date(timeIntervalSince1970: 2))
            } ?? .pending
        )
    }

    private func webSocket() -> Flow {
        var flow = flow(url: "https://a.test/socket", status: 101, contentType: nil)
        flow.webSocketMessages = []
        return flow
    }

    // MARK: Classification

    @Test func transportReadsTheSchemeAndLetsAWebSocketWin() {
        #expect(FlowQuickFilter.transport(of: flow(url: "http://a.test/1")) == .http)
        #expect(FlowQuickFilter.transport(of: flow(url: "https://a.test/1")) == .https)
        // Captured on the URL it upgraded from, so the scheme alone would say HTTPS.
        #expect(FlowQuickFilter.transport(of: webSocket()) == .webSocket)
    }

    /// The chip has to select what the Protocol column *says*, or it picks rows that
    /// read as something else. `MainView.protocolLabel` prints `WS`/`WSS` for a
    /// `ws(s)://` URL whether or not a frame has been relayed yet, so the chip does too.
    @Test func aWebSocketURLIsAWebSocketRowBeforeAnyFrame() {
        for url in ["ws://a.test/s", "wss://a.test/s"] {
            let pending = flow(url: url, status: nil, contentType: nil)
            #expect(FlowQuickFilter.transport(of: pending) == .webSocket)
            #expect(MainView.protocolLabel(pending).hasPrefix("WS"))
        }
    }

    /// A record with no scheme is unclassified rather than guessed as HTTPS: a
    /// tunnelled connection need not be TLS at all.
    @Test func aSchemelessRecordIsNotGuessed() {
        #expect(FlowQuickFilter.transport(of: flow(url: "a.test:443")) == nil)
    }

    @Test func theVersionIsTheClientLegAndFoldsTheOnePointOhs() {
        #expect(FlowQuickFilter.httpVersion(of: flow(version: "HTTP/1.0")) == .http1)
        #expect(FlowQuickFilter.httpVersion(of: flow(version: "HTTP/1.1")) == .http1)
        #expect(FlowQuickFilter.httpVersion(of: flow(version: "HTTP/2")) == .http2)
        #expect(FlowQuickFilter.httpVersion(of: flow(version: nil)) == nil)
    }

    @Test(arguments: [
        ("application/json", QuickContentKind.json),
        ("application/ld+json", .json),
        ("text/json; charset=utf-8", .json),
        ("text/html", .html),
        ("application/xhtml+xml", .html),
        ("text/xml", .xml),
        ("application/soap+xml", .xml),
        ("application/javascript", .javascript),
        ("text/plain", .text),
        ("image/png", .image),
        ("video/mp4", .media),
        ("audio/mpeg", .media),
        ("application/octet-stream", .binary),
        ("application/grpc", .binary),
        // An image whose type ends in `+xml`: the media-type prefixes are tested
        // before the structured-suffix ones for exactly this.
        ("image/svg+xml", .image),
        ("IMAGE/PNG", .image),
        ("application/json ; charset=utf-8", .json),
        ("application/x-www-form-urlencoded", .text),
    ])
    func contentIsReadOffTheResponseType(_ raw: String, _ expected: QuickContentKind) {
        #expect(FlowQuickFilter.contentKind(of: flow(contentType: raw)) == expected)
    }

    @Test func aHeaderNameMatchesWhateverCaseTheWireUsed() {
        let headers = [HeaderPair(name: "CONTENT-type", value: "application/json")]
        #expect(FlowQuickFilter.contentTypeValue(headers) == "application/json")
        #expect(FlowQuickFilter.contentTypeValue([HeaderPair(name: "Content-Length", value: "4")]) == nil)
    }

    /// `binary` means *typed and none of the above*. A row with no response yet, or a
    /// response with no `Content-Type`, matches no content chip — absent is unmeasured,
    /// never "no". Folding the unknowns into `binary` would make "show me the binary
    /// payloads" return every pending exchange in the window.
    @Test func anUnclassifiableRowIsNotFoldedIntoBinary() {
        #expect(FlowQuickFilter.contentKind(of: flow(status: nil, contentType: nil)) == nil)
        #expect(FlowQuickFilter.contentKind(of: flow(contentType: nil)) == nil)

        let filter = FlowQuickFilter([.content(.binary)])
        #expect(filter.predicate()(flow(status: nil, contentType: nil)) == false)
        #expect(filter.predicate()(flow(contentType: "application/octet-stream")))
    }

    @Test func statusIsClassifiedByHundreds() {
        #expect(FlowQuickFilter.statusClass(of: flow(status: 204)) == .success)
        #expect(FlowQuickFilter.statusClass(of: flow(status: 404)) == .clientError)
        #expect(FlowQuickFilter.statusClass(of: flow(status: nil)) == nil)
    }

    // MARK: What a set of chips means

    @Test func chipsAreORedWithinAFacet() {
        let filter = FlowQuickFilter([.status(.clientError), .status(.serverError)])
        let matches = filter.predicate()
        #expect(matches(flow(status: 404)))
        #expect(matches(flow(status: 503)))
        #expect(!matches(flow(status: 200)))
    }

    @Test func facetsAreANDedAcross() {
        let filter = FlowQuickFilter([.transport(.https), .content(.json), .status(.serverError)])
        let matches = filter.predicate()
        #expect(matches(flow(url: "https://a.test/1", status: 500, contentType: "application/json")))
        #expect(!matches(flow(url: "http://a.test/1", status: 500, contentType: "application/json")))
        #expect(!matches(flow(url: "https://a.test/1", status: 200, contentType: "application/json")))
        #expect(!matches(flow(url: "https://a.test/1", status: 500, contentType: "text/html")))
    }

    @Test func anEmptyFilterAdmitsEverything() {
        let filter = FlowQuickFilter()
        #expect(!filter.isActive)
        #expect(filter.predicate()(flow(status: nil, contentType: nil)))
    }

    @Test func toggleIsSymmetricAndClearDropsEverything() {
        var filter = FlowQuickFilter()
        filter.toggle(.content(.image))
        #expect(filter.contains(.content(.image)))
        filter.toggle(.content(.image))
        #expect(!filter.isActive)
        filter.toggle(.status(.success))
        filter.toggle(.transport(.http))
        filter.clear()
        #expect(!filter.isActive)
    }

    /// The bar draws `QuickFilterChip.all`, so a facet case that never reached that
    /// list is a filter with no control — invisible in review and in the window.
    @Test func everyChipIsReachableFromTheBarsList() {
        let expected = QuickTransport.allCases.count + QuickHTTPVersion.allCases.count
            + QuickContentKind.allCases.count + QuickStatusClass.allCases.count
        #expect(QuickFilterChip.all.count == expected)
        #expect(Set(QuickFilterChip.all).count == expected, "no chip is listed twice")
    }

    @Test func theMediaTypeIsTakenWithoutItsParametersOrWhitespace() {
        #expect(FlowQuickFilter.mediaType(of: " application/json ; charset=utf-8") == "application/json")
        #expect(FlowQuickFilter.mediaType(of: "text/html") == "text/html")
        #expect(FlowQuickFilter.mediaType(of: "; charset=utf-8").isEmpty)
        // A parameter is never matched against: this is what stops
        // `text/plain; charset=x-json` from reading as JSON.
        #expect(FlowQuickFilter.contentKind(of: flow(contentType: "text/plain; charset=x-json")) == .text)
    }

    @Test func theASCIIFoldMatchesWhatTheStandardOperatorsWould() {
        #expect(FlowQuickFilter.hasASCIIPrefix("IMAGE/png", "image/"))
        #expect(!FlowQuickFilter.hasASCIIPrefix("im", "image/"), "a needle longer than the haystack")
        #expect(FlowQuickFilter.containsASCII("application/LD+Json", "json"))
        #expect(!FlowQuickFilter.containsASCII("application/json", "protobuf"))
        #expect(!FlowQuickFilter.containsASCII("js", "json"), "a needle longer than the haystack")
    }

    // MARK: The window

    @Test func chipsNarrowTheProjectionAndComposeWithTheSidebar() {
        var state = CaptureFeature.State()
        state.recordFlows([
            flow(url: "https://a.test/1", status: 500, contentType: "application/json"),
            flow(url: "https://b.test/1", status: 500, contentType: "application/json"),
            flow(url: "https://a.test/2", status: 200, contentType: "application/json"),
        ])
        state.quickFilter.toggle(.status(.serverError))
        #expect(state.displayFlows.count == 2)
        state.selectedCategory = .host("a.test")
        #expect(state.displayFlows.count == 1, "the chip ANDs with the sidebar rather than replacing it")
        state.quickFilter.clear()
        #expect(state.displayFlows.count == 2)
    }

    /// The incremental fold and the full rebuild are two writers of one cached list,
    /// so a chip has to be applied by both — the same argument `VisibleProjectionTests`
    /// makes for the sidebar and the needle.
    @Test func theIncrementalFoldAgreesWithARebuildUnderAChip() {
        var state = CaptureFeature.State()
        state.recordFlows((0 ..< 20).map { flow(url: "https://a.test/\($0)", status: $0.isMultiple(of: 2) ? 200 : 404) })
        state.quickFilter.toggle(.status(.clientError))
        state.recordFlows((20 ..< 30).map { flow(url: "https://a.test/\($0)", status: $0.isMultiple(of: 3) ? 404 : 200) })

        var rebuilt = state
        rebuilt.refreshVisibleFlows()
        #expect(state.displayFlows.map(\.id) == rebuilt.displayFlows.map(\.id))
        #expect(!state.displayFlows.isEmpty)
    }

    @Test func toggleAndClearRunThroughTheReducer() async {
        let store = await TestStore(initialState: CaptureFeature.State()) {
            CaptureFeature()
        }
        await store.send(.quickFilterToggled(.content(.image))) {
            $0.quickFilter.toggle(.content(.image))
        }
        await store.send(.quickFilterCleared) {
            $0.quickFilter.clear()
        }
    }
}
