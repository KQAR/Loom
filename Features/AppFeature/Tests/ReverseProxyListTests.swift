import Foundation
import LoomSharedModels
import Testing
@testable import AppFeature

/// What the console's reverse-proxy card draws. Derivation is tested rather than the
/// view, because the case that justifies the list at all — an endpoint whose port
/// didn't bind — is the one nobody reproduces on demand while looking at a preview.
@Suite struct ReverseProxyListTests {
    private func status(
        port: Int = 9200, upstream: String = "https://api.github.com",
        bound: Int? = 9200, error: String? = nil, label: String? = nil,
        keepHost: Bool = false, createdAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> ReverseProxyStatus {
        ReverseProxyStatus(
            endpoint: ReverseProxyEndpoint(
                requestedPort: port, upstream: upstream, label: label,
                keepHostHeader: keepHost, createdAt: createdAt),
            boundPort: bound, error: error
        )
    }

    @Test func noEndpointsDrawNothing() {
        let result = ReverseProxyList.rows(for: [])
        #expect(result.rows.isEmpty)
        #expect(result.hidden == 0)
    }

    /// The primary line is what a client gets pointed at, so it is the local URL —
    /// copyable into a dev server's config as-is.
    @Test func aListeningEndpointShowsItsLocalURL() {
        #expect(ReverseProxyList.target(for: status(bound: 9200)) == "http://127.0.0.1:9200")
    }

    @Test func theCaptionNamesTheUpstreamItForwardsTo() {
        #expect(ReverseProxyList.caption(for: status()) == "→ https://api.github.com")
    }

    @Test func aLabelAndKeepHostAreAppendedSoTwoEndpointsToOneHostAreTellableApart() {
        let caption = ReverseProxyList.caption(for: status(label: "checkout", keepHost: true))
        #expect(caption == "→ https://api.github.com · checkout · keeps Host header")
    }

    // MARK: The case this exists for

    /// A bind failure has to be readable in full: the client experiences it as
    /// connection refused, which reads as Loom being down rather than as this endpoint
    /// being broken.
    @Test func aFailedBindCarriesTheReasonRatherThanJustAFlag() {
        let failed = status(bound: nil, error: "could not listen on port 9200: Address already in use")
        #expect(ReverseProxyList.caption(for: failed)
            == "Not listening — could not listen on port 9200: Address already in use")
    }

    /// With no bound port the *requested* one is named — that is the number written in
    /// a dev server's config, so it is the one the human recognizes.
    @Test func aFailedBindNamesThePortThatWasAskedFor() {
        #expect(ReverseProxyList.target(for: status(port: 9345, bound: nil, error: "boom"))
            == "port 9345 — not listening")
    }

    @Test func faultsSortAboveListeningEndpoints() {
        let rows = ReverseProxyList.rows(for: [
            status(port: 9200, bound: 9200, createdAt: Date(timeIntervalSince1970: 1_000)),
            status(port: 9201, bound: nil, error: "taken", createdAt: Date(timeIntervalSince1970: 2_000)),
        ]).rows
        #expect(rows.first?.isListening == false, "the fault must not sit below healthy endpoints")
    }

    @Test func listeningEndpointsKeepACreationOrderSoTheListDoesNotReshuffle() {
        let rows = ReverseProxyList.rows(for: [
            status(port: 9201, bound: 9201, createdAt: Date(timeIntervalSince1970: 2_000)),
            status(port: 9200, bound: 9200, createdAt: Date(timeIntervalSince1970: 1_000)),
        ]).rows
        #expect(rows.map { $0.boundPort } == [9200, 9201])
    }

    // MARK: Bounded, and honest about it

    @Test func moreEndpointsThanFitCollapseIntoACount() {
        let many = (0 ..< (ReverseProxyList.visibleLimit + 3)).map {
            status(port: 9200 + $0, bound: 9200 + $0, createdAt: Date(timeIntervalSince1970: Double(1_000 + $0)))
        }
        let result = ReverseProxyList.rows(for: many)
        #expect(result.rows.count == ReverseProxyList.visibleLimit)
        #expect(result.hidden == 3)
    }

    /// If truncation ever hides something it must not be the fault — an endpoint that
    /// isn't listening is the only entry here worth its vertical space.
    @Test func truncationNeverHidesAFault() {
        var endpoints = (0 ..< ReverseProxyList.visibleLimit).map {
            status(port: 9200 + $0, bound: 9200 + $0, createdAt: Date(timeIntervalSince1970: Double(1_000 + $0)))
        }
        endpoints.append(status(port: 9500, bound: nil, error: "taken", createdAt: Date(timeIntervalSince1970: 9_999)))
        let result = ReverseProxyList.rows(for: endpoints)
        #expect(result.rows.contains { !$0.isListening })
        #expect(result.hidden > 0)
    }
}
