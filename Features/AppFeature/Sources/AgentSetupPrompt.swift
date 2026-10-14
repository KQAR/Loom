import AppKit
import SwiftUI

/// A prompt the human pastes into their agent so the *agent* installs Loom's skill
/// and MCP server — Loom's operator is an agent, so the agent should do its own setup.
///
/// It names this copy's `install-agent.sh` by its real bundle path rather than
/// `/Applications`, so a Loom run from anywhere else hands out a command that works.
enum AgentSetupPrompt {
    /// Where the bundled installer is; `/Applications` only when the bundle has no
    /// such resource (a test host).
    static var scriptPath: String {
        Bundle.main.path(forResource: "install-agent", ofType: "sh")
            ?? "/Applications/Loom.app/Contents/Resources/install-agent.sh"
    }

    static func text(scriptPath: String = scriptPath) -> String {
        let script = shellQuoted(scriptPath)
        return """
        Set up Loom for yourself. Loom is the HTTP/HTTPS debugging proxy running on this Mac; \
        it ships an agent skill and serves MCP tools on http://127.0.0.1:9092/mcp. Run ONE of \
        these, matching the agent you are:

          sh \(script) claude   # Claude Code
          sh \(script) cursor   # Cursor

        The script links Loom's bundled skill into your skills directory (so it updates with \
        the app), registers the `loom` MCP server, and removes the old `loom@loom` plugin if \
        it is installed. Show me its output, then tell me to restart you so the skill and the \
        tools load.
        """
    }

    @MainActor static func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(), forType: .string)
    }

    /// POSIX single-quoting: a bundle path may hold spaces, and in principle a quote.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// Loom ▸ Copy Agent Setup Prompt — the copy that outlives the empty state, which
/// is gone once the first request lands.
public struct AgentSetupCommands: Commands {
    public init() {}

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Copy Agent Setup Prompt") { AgentSetupPrompt.copy() }
        }
    }
}
