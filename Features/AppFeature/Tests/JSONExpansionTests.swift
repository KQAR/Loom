import Testing

@testable import AppFeature

/// The Body pane's expand-all / collapse-all.
///
/// The resolution lives on `JSONExpansionCommand` rather than inside the node view so
/// it can be checked here: it is a precedence rule between four sources — the find,
/// the reader's own click, the last whole-tree command and the default — and the
/// failures it is written against (a branch that reopens itself, a command that misses
/// the nodes below the fold) are invisible in a screenshot.
@Suite struct JSONExpansionTests {
    private func resolve(
        _ command: JSONExpansionCommand,
        depth: Int = 5,
        userExpanded: Bool? = nil,
        userGeneration: Int = 0,
        findExpanded: Bool = false
    ) -> Bool {
        command.resolve(
            depth: depth,
            userExpanded: userExpanded,
            userGeneration: userGeneration,
            findExpanded: findExpanded
        )
    }

    @Test func withNoCommandTheTopTwoLevelsAreOpen() {
        let command = JSONExpansionCommand()
        #expect(resolve(command, depth: 0))
        #expect(resolve(command, depth: 1))
        #expect(!resolve(command, depth: 2))
        #expect(!command.isExpandedAll, "the button offers Expand All before anything is commanded")
    }

    @Test func aCommandReachesEveryDepth() {
        var command = JSONExpansionCommand()
        command.expandAll()
        #expect(resolve(command, depth: 12))
        #expect(command.isExpandedAll)
        command.collapseAll()
        #expect(!resolve(command, depth: 1))
        #expect(!resolve(command, depth: 12))
        #expect(!command.isExpandedAll)
    }

    /// Collapse-all folds to the top level, not to nothing: closing the root would
    /// replace the pane with one `{…}` line — a hidden body rather than a collapsed
    /// one, with nothing left to read and one chevron to undo it.
    @Test func collapseAllLeavesTheOutermostContainerOpen() {
        var command = JSONExpansionCommand()
        command.collapseAll()
        #expect(resolve(command, depth: 0))
        #expect(!resolve(command, depth: 1))
        // Still closable by hand — the exemption is the command's, not the node's.
        #expect(!resolve(command, depth: 0, userExpanded: false, userGeneration: command.generation))
    }

    /// The case the generation stamp exists for: after expanding everything, closing
    /// one branch has to stick — a per-render recomputation that let the command win
    /// again would reopen it on the next inspector update, which under live capture is
    /// ten times a second.
    @Test func aClickAfterACommandWins() {
        var command = JSONExpansionCommand()
        command.expandAll()
        #expect(!resolve(command, userExpanded: false, userGeneration: command.generation))
        #expect(resolve(command, userExpanded: true, userGeneration: command.generation))
    }

    /// And the converse: the *next* command supersedes every stored choice at once,
    /// including one made under the previous command.
    @Test func theNextCommandSupersedesAStoredClick() {
        var command = JSONExpansionCommand()
        command.expandAll()
        let staleGeneration = command.generation
        command.collapseAll()
        #expect(!resolve(command, userExpanded: true, userGeneration: staleGeneration))
        command.expandAll()
        #expect(resolve(command, userExpanded: false, userGeneration: staleGeneration))
    }

    /// A node a find hit sits under stays open whatever else says otherwise — the rule
    /// `JSONNode.isExpanded` has always held for the reader's own collapse, now also
    /// against a collapse-all.
    @Test func aFindHitIsNeverClosed() {
        var command = JSONExpansionCommand()
        command.collapseAll()
        #expect(resolve(command, findExpanded: true))
        #expect(resolve(command, userExpanded: false, userGeneration: command.generation, findExpanded: true))
    }
}
