import Foundation
import LoomSharedModels

/// JSON rendering of a `FlowComparison` for the `diff_flows` tool.
///
/// The comparison **semantics** live in `FlowComparison` (SharedModels), because
/// the Inspector's diff pane renders the same value — an agent and the human
/// supervising it must not be shown two different answers to "what did the replay
/// change". This file is only the wire shape, and even that is now delegated:
/// `FlowDiffRender` & co. in `MCPRenderModels.swift` are the keys and the nesting,
/// so the census in `RenderParityTests` can check them field by field. This diff
/// was the last agent-facing render still hand-building a `[String: Any]`, which
/// is exactly the hole that census exists to close — a field added to
/// `FlowComparison` compiled fine and the agent silently never saw it.
///
/// A rule about *what counts as a difference* belongs next to the model, not here.
enum FlowDiff {
    /// Diff `compared` against `base`, rendered as the tool's JSON object. Only
    /// the parts that actually differ appear; `identical` is true when nothing did.
    static func diff(base: Flow, compared: Flow) -> [String: Any] {
        render(FlowComparison.compare(base: base, compared: compared))
    }

    static func render(_ comparison: FlowComparison) -> [String: Any] {
        MCPRender.dict(FlowDiffRender(comparison))
    }

    // MARK: - Test seams
    //
    // The unit tests exercise the two pieces most likely to regress silently
    // (header grouping and the body/line diff) through these, so they keep
    // testing the shipped semantics now that those live in SharedModels.

    static func headerDiff(_ base: [HeaderPair], _ compared: [HeaderPair]) -> [String: Any] {
        MCPRender.dict(HeaderDiffRender(FlowComparison.compareHeaders(base, compared)))
    }

    static func bodyDiff(
        _ base: Data?,
        _ compared: Data?,
        baseWireBytes: Int? = nil,
        comparedWireBytes: Int? = nil
    ) -> [String: Any] {
        FlowComparison.compareBodies(
            base, compared, baseWireBytes: baseWireBytes, comparedWireBytes: comparedWireBytes
        )
        .map { MCPRender.dict(BodyDiffRender($0)) } ?? [:]
    }

    static func lineDiff(_ a: [String], _ b: [String]) -> (added: [String], removed: [String]) {
        FlowComparison.lineDiff(a, b)
    }
}
