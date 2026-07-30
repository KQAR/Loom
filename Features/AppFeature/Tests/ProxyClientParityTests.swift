import Foundation
import LoomSharedModels
import ProxyClient
import Testing

/// Keeps the human's control surface from silently falling behind the agent's.
///
/// The engine's write surface (`ProxyControlling`) has two consumers: `MCPServer`
/// reaches it directly — so the compiler keeps that side complete — and
/// `ProxyClient` mirrors it by hand for the UI, where the compiler checks nothing.
/// The mirror had already drifted: every breakpoint capability was reachable over
/// MCP and absent from `ProxyClient`, which meant an agent could park a live client
/// connection with no way for the supervising human to see it or let it go.
///
/// The guard is the exhaustive `switch` below. A new `ProxyCapability` case (which
/// the protocol's doc comment requires when a requirement is added) fails to
/// compile here until it is either mapped to a real `ProxyClient` endpoint or
/// recorded as `.deliberatelyAbsent` **with a reason** — an omission has to be
/// written down, not merely forgotten.
@Suite struct ProxyClientParityTests {
    /// How one engine capability relates to the human surface.
    enum Coverage {
        /// Reachable from the UI. The associated value exists only to make the
        /// mapping reference the endpoint, so a renamed/removed field is a
        /// compile error rather than a stale string.
        case wired(Any)
        /// Intentionally not on the human surface, for this reason.
        case deliberatelyAbsent(String)
    }

    /// The whole point of the suite: a total function from capability to coverage.
    func coverage(of capability: ProxyCapability, in client: ProxyClient) -> Coverage {
        switch capability {
        // MARK: FlowProviding
        case .status: return .wired(client.status)
        case .recentFlows: return .wired(client.recentFlows)
        case .recentFlowsMatching: return .wired(client.recentFlowsMatching)
        case .recentFlowsForExport:
            return .deliberatelyAbsent("""
            HAR export is an agent action (export_har); the window has no export \
            affordance, and a body-hydrating read is the wrong thing to hand a view.
            """)
        case .flowByID: return .wired(client.flow)
        case .flowStream: return .wired(client.flowStream)
        case .connectedDevices: return .wired(client.connectedDevices)
        case .flowsClearedStream: return .wired(client.flowsClearedStream)

        // MARK: FlowReplaying
        case .replayByID: return .wired(client.replay)
        case .replayFlow:
            return .deliberatelyAbsent("""
            The retention-independent form exists for embedders that keep their own \
            store. The window always holds an id the engine can resolve.
            """)

        // MARK: TLSInterceptControlling
        case .certificateStatus: return .wired(client.certificateStatus)
        case .exportCACertificate: return .wired(client.exportCACertificate)
        case .sslScope: return .wired(client.sslScope)
        case .setSSLScope: return .wired(client.setSSLScope)

        // MARK: CaptureControlling
        case .importFlows:
            return .deliberatelyAbsent("""
            HAR import is agent-only today (import_har). Wire this the moment the \
            window grows a drop target — the flows land in the shared store either way.
            """)
        case .setRecording: return .wired(client.setRecording)
        case .clearFlows: return .wired(client.clearFlows)

        // MARK: RulesControlling
        case .rulesState: return .wired(client.rulesState)
        case .setRulesEnabled: return .wired(client.setRulesEnabled)
        case .addRule: return .wired(client.addRule)
        case .updateRule: return .wired(client.updateRule)
        case .deleteRule: return .wired(client.deleteRule)
        case .setRules:
            return .deliberatelyAbsent("""
            Wholesale replace is for a host that owns the rule set elsewhere and \
            syncs it. The editor edits one rule at a time, through add/update/delete.
            """)
        case .setGroupEnabled: return .wired(client.setGroupEnabled)

        // MARK: BreakpointControlling
        case .armBreakpoint: return .wired(client.armBreakpoint)
        case .disarmBreakpoint: return .wired(client.disarmBreakpoint)
        case .armedBreakpoints: return .wired(client.armedBreakpoints)
        case .pendingBreakpoints: return .wired(client.pendingBreakpoints)
        case .pendingBreakpointStream: return .wired(client.pendingBreakpointStream)
        case .resumeBreakpoint: return .wired(client.resumeBreakpoint)

        // MARK: AuditControlling
        case .recordAudit:
            return .deliberatelyAbsent("""
            Writing the trail belongs to the one MCP choke point (MCPToolExecutor.call). \
            The human reads it; a second writer would let a UI action forge an entry.
            """)
        case .recentAuditEntries: return .wired(client.recentAuditEntries)
        case .auditStream: return .wired(client.auditStream)
        case .clearAudit: return .wired(client.clearAudit)

        // MARK: ClientCertificateControlling
        //
        // Wired from the start, unlike HAR import above: which credential Loom
        // presents to a third party is precisely the write the human has to be able
        // to see and revoke without asking the agent to do it.
        case .clientCertificates: return .wired(client.clientCertificates)
        case .setClientCertificate: return .wired(client.setClientCertificate)
        case .deleteClientCertificate: return .wired(client.deleteClientCertificate)
        }
    }

    @Test func everyEngineCapabilityIsAccountedFor() {
        // Compiling at all is the guard. This asserts the mapping is total at
        // runtime too, and that a deliberate omission carries a real reason
        // rather than an empty string.
        let client = ProxyClient.testValue
        for capability in ProxyCapability.allCases {
            switch coverage(of: capability, in: client) {
            case .wired:
                break
            case let .deliberatelyAbsent(reason):
                #expect(reason.count > 20, "\(capability.rawValue): omission needs a real reason")
            }
        }
    }

    /// The gap this suite was written for: breakpoints reachable over MCP but not
    /// from the human surface. Pinned by name so a future refactor that drops them
    /// from `ProxyClient` fails here loudly instead of quietly re-opening it.
    @Test func breakpointSupervisionIsReachableFromTheHumanSurface() {
        let client = ProxyClient.testValue
        let breakpointCapabilities: [ProxyCapability] = [
            .armBreakpoint, .disarmBreakpoint, .armedBreakpoints,
            .pendingBreakpoints, .pendingBreakpointStream, .resumeBreakpoint,
        ]
        for capability in breakpointCapabilities {
            guard case .wired = coverage(of: capability, in: client) else {
                Issue.record("\(capability.rawValue) must stay on the human surface")
                continue
            }
        }
    }
}
// Note: the suite deliberately never touches `ProxyClient.liveValue` — that would
// boot `ProxyEngine.shared`, i.e. the real SQLite stores, the rules file and the CA
// migration, inside a unit test. `liveValue`'s completeness is a compile-time
// property (every field is assigned in its initializer), which is exactly what the
// mapping above leans on.
