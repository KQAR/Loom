import Foundation
import Testing

@testable import AppFeature

/// `AuditFeature.liveStreamedTools` names tools by string, and nothing checked that
/// the strings name anything.
///
/// ## What the list does
///
/// Every MCP write tool lands in the audit trail, and `AuditFeature` fans that out
/// into a coalesced re-read of `status` + rules + interception — the inversion that
/// replaced an allowlist of two tools out of twenty. `liveStreamedTools` is the
/// **opt-out**: the tools that already reach the human through a live stream of
/// their own, so a re-read would be pure waste.
///
/// ## What was unguarded
///
/// The entries are matched against `AuditEntry.tool` with `Set.contains`. A tool
/// renamed in the registry — or a typo written here — silently stops matching, and
/// the opt-out quietly becomes a no-op. `replay_flow` is the entry where that costs
/// something measurable: `replay_flow(count:)` arrives in batches, and every one of
/// a hundred replays would then schedule a `status()` re-read, which hops onto
/// `FlowStore`, which every capture write queues on.
///
/// It fails in the safe direction, which is exactly why nothing would ever have
/// noticed. Nothing breaks; the window just does redundant work forever.
///
/// ## Why it is checked this way
///
/// `AppFeature` cannot import `MCPServer` — they are siblings, and the dependency
/// direction is one-way — so the registry is read from disk through `#filePath`, the
/// same seam `VersionFieldParityTests` uses for the version manifests. It fails if
/// the file moves, which is intended: a registry that moved without this moving with
/// it is a check that stopped being maintained.
@Suite struct AuditOptOutParityTests {
    private static let registry = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // AppFeature
        .deletingLastPathComponent()  // Features
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("Engine/MCPServer/Sources/MCPToolSchemas.swift")

    /// Every `name: "…"` in the tool table.
    private func advertisedToolNames() throws -> Set<String> {
        let source = try String(contentsOf: Self.registry, encoding: .utf8)
        let matches = source.ranges(of: #/name: "(?<tool>[a-z_]+)"/#)
        let names = Set(matches.map { String(source[$0].split(separator: "\"")[1]) })
        #expect(
            names.count > 20,
            "found only \(names.count) tool names — the registry's shape changed and this parse is no longer reading it"
        )
        return names
    }

    @Test func everyOptOutNamesARealTool() throws {
        let advertised = try advertisedToolNames()
        for tool in AuditFeature.liveStreamedTools.sorted() {
            #expect(
                advertised.contains(tool),
                """
                `liveStreamedTools` opts out of "\(tool)", which no tool is called. \
                The entry matches nothing, so that tool — if it still exists under \
                another name — now triggers a full mirror re-read on every call. \
                Rename it here, or drop it if the tool is gone.
                """
            )
        }
    }

    /// The other half of the doc comment on that set: "Anything added here needs a
    /// live stream to point at." A tool opted out without one reaches the human on no
    /// surface at all, which is the failure the inversion was written to end — and it
    /// is the *unsafe* direction, unlike a stale name.
    @Test func everyOptOutHasAStreamNamedBesideIt() throws {
        let source = try String(contentsOf: Self.registry, encoding: .utf8)
        _ = source // read for the same failure mode as above: a moved registry fails here too

        // The three streams that make an opt-out legitimate, and which tools ride
        // each. Stated here rather than parsed, because "this write reaches the human
        // through that stream" is a claim about behaviour, not about a string.
        let streams: [String: Set<String>] = [
            "flowStream / flowsClearedStream": ["replay_flow", "clear_flows", "import_har"],
            "pendingBreakpointStream": ["arm_breakpoint", "disarm_breakpoint", "resume"],
        ]
        let accounted = streams.values.reduce(into: Set<String>()) { $0.formUnion($1) }

        let unaccounted = AuditFeature.liveStreamedTools.subtracting(accounted)
        #expect(
            unaccounted.isEmpty,
            """
            \(unaccounted.sorted()) opt out of the mirror re-read with no live stream \
            named beside them. A write that reaches the human through neither is \
            invisible until the window is reopened, which for the main window means \
            until relaunch. Name the stream here, or take the tool out of the opt-out.
            """
        )
        let stale = accounted.subtracting(AuditFeature.liveStreamedTools)
        #expect(
            stale.isEmpty,
            "\(stale.sorted()) are listed as streamed here but no longer opt out — drop them."
        )
    }
}
