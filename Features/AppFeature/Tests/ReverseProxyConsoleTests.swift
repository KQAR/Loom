import ComposableArchitecture
import Foundation
import LoomSharedModels
import Testing
@testable import AppFeature

/// The console's *write* half of reverse-proxy endpoints — creating and removing one
/// from the status-bar panel, which was agent-only before.
///
/// What these pin is the two things a create can't fake: that the list the panel
/// draws comes from a re-read of the engine (so the *bound* port shows, not the
/// requested one), and that a failed create says why instead of quietly doing nothing.
@Suite struct ReverseProxyConsoleTests {
    private func endpoint(
        port: Int = 9200, upstream: String = "https://api.github.com", bound: Int? = 9200,
        error: String? = nil
    ) -> ReverseProxyStatus {
        ReverseProxyStatus(
            endpoint: ReverseProxyEndpoint(requestedPort: port, upstream: upstream),
            boundPort: bound, error: error
        )
    }

    /// Blank port in the form means "any free one" (requested 0), and the OS's choice
    /// is the number the human has to type into a config file — so the create is
    /// followed by a status re-read rather than by trusting what was submitted.
    @MainActor
    @Test func creatingAnEndpointReReadsTheEngineSoTheBoundPortIsWhatShows() async {
        let created = endpoint(port: 0, bound: 54_321)
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.createReverseProxy = { _ in created }
            $0.proxyClient.status = {
                ProxyStatus(isRunning: true, port: 9090, capturedCount: 0, reverseProxies: [created])
            }
        }

        await store.send(.addReverseProxyTapped(
            upstream: "https://api.github.com", port: 0, label: nil, keepHostHeader: false
        )) {
            $0.reverseProxyBusy = true
        }
        await store.receive(\.engineStatusRefreshed) {
            $0.status.port = 9090
            $0.status.reverseProxies = [created]
        }
        await store.receive(\.reverseProxyFinished) {
            $0.reverseProxyBusy = false
        }
        #expect(store.state.status.reverseProxies.first?.localURL == "http://127.0.0.1:54321")
        #expect(store.state.reverseProxyMessage == nil)
    }

    /// A create binds before it persists, so the common failure — the port is already
    /// taken by the very dev server the endpoint was made for — arrives as a throw.
    /// The engine's message names the port, so it is relayed verbatim rather than
    /// replaced with "couldn't add".
    @MainActor
    @Test func aFailedCreateSurfacesTheEnginesReasonAndClearsBusy() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.createReverseProxy = { _ in
                throw ProxyControlError.invalidReverseProxy("port 9200 is already in use")
            }
        }

        await store.send(.addReverseProxyTapped(
            upstream: "https://api.github.com", port: 9200, label: nil, keepHostHeader: false
        )) {
            $0.reverseProxyBusy = true
        }
        await store.receive(\.reverseProxyFinished) {
            $0.reverseProxyBusy = false
            // Verbatim from `ProxyControlError.message`, kind prefix included: the
            // panel shows the engine's wording, not a rewrite of it.
            $0.reverseProxyMessage = "invalid reverse proxy: port 9200 is already in use"
        }
        // No status re-read on failure: nothing changed, and a refresh would imply it did.
        #expect(store.state.status.reverseProxies.isEmpty)
    }

    @MainActor
    @Test func removingAnEndpointDropsItFromTheListThePanelDraws() async {
        let existing = endpoint()
        var state = AppFeature.State()
        state.status.reverseProxies = [existing]
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.deleteReverseProxy = { _ in }
            $0.proxyClient.status = { ProxyStatus(isRunning: true, port: 9090, capturedCount: 0) }
        }

        await store.send(.deleteReverseProxyTapped(id: existing.endpoint.id)) {
            $0.reverseProxyBusy = true
        }
        await store.receive(\.engineStatusRefreshed) {
            $0.status.port = 9090
            $0.status.reverseProxies = []
        }
        await store.receive(\.reverseProxyFinished) {
            $0.reverseProxyBusy = false
        }
    }

    /// Opening the section re-reads, because the other writer is an agent: an endpoint
    /// created over MCP since the last refresh would otherwise be missing from the list
    /// the human just opened to check.
    @MainActor
    @Test func openingTheSectionReReadsTheEndpoints() async {
        let agents = endpoint(port: 9300, upstream: "https://api.stripe.com", bound: 9300)
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.status = {
                ProxyStatus(isRunning: true, port: 9090, capturedCount: 0, reverseProxies: [agents])
            }
        }

        await store.send(.reverseProxiesExpandTapped) {
            $0.reverseProxiesExpanded = true
        }
        await store.receive(\.engineStatusRefreshed) {
            $0.status.port = 9090
            $0.status.reverseProxies = [agents]
        }

        // Collapsing reads nothing — there is no list on screen to keep fresh.
        await store.send(.reverseProxiesExpandTapped) {
            $0.reverseProxiesExpanded = false
        }
    }
}
