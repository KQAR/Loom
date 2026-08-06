import Testing
import Foundation
import LoomSharedModels
@testable import MCPServer

/// An empty capture has two very different causes: nothing happened, or nothing was
/// routed through Loom. Until now an agent could not tell them apart — the whole
/// routing surface lived in the app's UI — so it would report "no traffic" when the
/// truth was "no proxy". These tools close that hole, and the thing that must not
/// regress is honesty: "can't tell" is reported as its own answer, and a switch flip
/// is confirmed by reading the state back rather than by trusting the return value.
@MainActor
@Suite struct SystemRoutingToolTests {
    private func makeExecutor(_ engine: StubEngine, routing: StubRouting?) -> MCPToolExecutor {
        MCPToolExecutor(
            engine: engine, appVersion: "9.9", protocolVersion: "2025-06-18", routing: routing
        )
    }

    private func json(_ string: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }

    @Test func statusReportsWhetherThisMacIsRoutedThroughLoom() async throws {
        let engine = StubEngine()
        let routing = StubRouting(active: true)

        let on = try await json(makeExecutor(engine, routing: routing).call(name: "get_proxy_status", arguments: [:]))
        #expect(on["systemProxy"] as? String == "on")

        await routing.set(active: false)
        let off = try await json(makeExecutor(engine, routing: routing).call(name: "get_proxy_status", arguments: [:]))
        #expect(off["systemProxy"] as? String == "off")
    }

    /// Three-valued, not two. Without a routing implementation the answer is
    /// "unavailable" — an agent that read `false` here would try to fix a problem it
    /// cannot observe, and then claim it had.
    @Test func withoutARoutingImplementation_statusSaysUnavailable_notOff() async throws {
        let out = try await json(makeExecutor(StubEngine(), routing: nil).call(name: "get_proxy_status", arguments: [:]))
        #expect(out["systemProxy"] as? String == "unavailable")
    }

    @Test func statusReportsTheListenAddressAndLANReach() async throws {
        let engine = StubEngine()
        engine.proxyStatus = ProxyStatus(
            isRunning: true, port: 9090, capturedCount: 3, isRecording: true, listenHost: "0.0.0.0"
        )
        let out = try await json(makeExecutor(engine, routing: nil).call(name: "get_proxy_status", arguments: [:]))
        #expect(out["listenHost"] as? String == "0.0.0.0")
        #expect(out["lanReachable"] as? Bool == true, "a phone can reach this one; loopback-only can't")
    }

    @Test func turningRoutingOn_confirmsByReadingTheStateBack() async throws {
        let routing = StubRouting(active: false)
        let out = try await json(makeExecutor(StubEngine(), routing: routing).call(
            name: "set_system_proxy", arguments: ["enabled": true]
        ))
        #expect(await routing.lastRequest == true)
        #expect(out["systemProxy"] as? String == "on")
        #expect(out["requested"] as? String == "on")
    }

    /// The nastiest case: the switch claims success but the setting didn't take (an
    /// admin prompt dismissed, a managed network service). Reporting the *requested*
    /// state would tell the agent traffic is being captured when none of it is.
    @Test func aChangeThatDidNotTake_isReportedAsStillOff() async throws {
        let routing = StubRouting(active: false, applyChangesState: false)
        let out = try await json(makeExecutor(StubEngine(), routing: routing).call(
            name: "set_system_proxy", arguments: ["enabled": true]
        ))
        #expect(out["requested"] as? String == "on")
        #expect(out["systemProxy"] as? String == "off", "read back, not assumed")
    }

    @Test func aFailedChangeIsAnInBandToolFailure() async throws {
        let routing = StubRouting(active: false, result: SystemRoutingResult(ok: false, message: "admin prompt cancelled"))
        await #expect(throws: MCPToolFailure.self) {
            try await makeExecutor(StubEngine(), routing: routing).call(
                name: "set_system_proxy", arguments: ["enabled": true]
            )
        }
    }

    @Test func withoutARoutingImplementation_theSwitchExplainsItself() async throws {
        await #expect(throws: MCPToolFailure.self) {
            try await makeExecutor(StubEngine(), routing: nil).call(
                name: "set_system_proxy", arguments: ["enabled": true]
            )
        }
    }

    @Test func routingTrafficAtAStoppedProxyIsRefused() async throws {
        let engine = StubEngine()
        engine.proxyStatus = ProxyStatus(isRunning: false, port: 9090, capturedCount: 0)
        let routing = StubRouting(active: false)

        await #expect(throws: MCPToolFailure.self) {
            try await makeExecutor(engine, routing: routing).call(
                name: "set_system_proxy", arguments: ["enabled": true]
            )
        }
        #expect(await routing.lastRequest == nil, "nothing was changed")

        // Turning it *off* with the proxy stopped is exactly how you recover from a
        // stale override, so that must still work.
        _ = try await makeExecutor(engine, routing: routing).call(
            name: "set_system_proxy", arguments: ["enabled": false]
        )
        #expect(await routing.lastRequest == false)
    }

    @Test func badArgumentsAreRejected() async throws {
        await #expect(throws: MCPError.self) {
            try await makeExecutor(StubEngine(), routing: StubRouting(active: false)).call(
                name: "set_system_proxy", arguments: ["enabled": "yes"]
            )
        }
    }

    /// It reconfigures the machine's networking, so it belongs in the trail the human
    /// reads; reading the status does not.
    @Test func flippingTheSwitchIsAudited_readingTheStatusIsNot() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine, routing: StubRouting(active: false))

        _ = try await executor.call(name: "get_proxy_status", arguments: [:])
        #expect(engine.recordedAudits.isEmpty)

        _ = try await executor.call(name: "set_system_proxy", arguments: ["enabled": true])
        #expect(engine.recordedAudits.map(\.tool) == ["set_system_proxy"])
        #expect(MCPToolExecutor.writeTools.contains("set_system_proxy"))
    }
}

/// Stand-in for the app's `SystemRoutingAdapter`.
private actor StubRouting: SystemRoutingControlling {
    private var active: Bool
    /// What `setSystemProxy` leaves the state as — `nil` means "whatever was asked",
    /// which is the normal case; `false` simulates a change that silently didn't take.
    private let applyChangesState: Bool?
    private let result: SystemRoutingResult
    /// Set to simulate another proxy app (Charles, whistle) owning the setting.
    private let occupant: (host: String, port: Int)?
    private let helper: PrivilegedHelperState
    private(set) var lastRequest: Bool?

    init(
        active: Bool, applyChangesState: Bool? = nil,
        result: SystemRoutingResult = SystemRoutingResult(ok: true),
        occupant: (host: String, port: Int)? = nil,
        helper: PrivilegedHelperState = .notInstalled
    ) {
        self.active = active
        self.applyChangesState = applyChangesState
        self.result = result
        self.occupant = occupant
        self.helper = helper
    }

    func set(active: Bool) { self.active = active }

    func isSystemProxyActive() async -> Bool { active }

    func privilegedHelper() async -> PrivilegedHelperState { helper }

    func privilegedHelperDetail() async -> String? { nil }

    func systemProxyRouting() async -> SystemProxyRouting {
        if active { return .loom }
        if let occupant { return .other(host: occupant.host, port: occupant.port) }
        return .off
    }

    func setSystemProxy(enabled: Bool) async -> SystemRoutingResult {
        lastRequest = enabled
        if result.ok { active = applyChangesState ?? enabled }
        return result
    }
}
