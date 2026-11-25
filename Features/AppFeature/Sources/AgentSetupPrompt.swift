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

        The script registers the `loom` MCP server, writes a small `loom` skill stub into \
        your skills directory (its guide is served by the running app over MCP, so it updates \
        with Loom), and removes the old `loom@loom` plugin if it is installed. Show me its \
        output, then tell me to restart you so the skill and the tools load. Later, \
        `sh \(script) skill status` shows whether the stub is installed and current, and \
        `skill remove` removes it.
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

/// Rewrites the skill stubs an older Loom wrote (`install-agent.sh skill setup
/// --installed-only`), run at launch so a Sparkle update — which relaunches — carries
/// its stub along. Installs nothing new: setup stays the human's or agent's decision.
public enum AgentSkillStubs {
    public static func refreshInstalled() {
        // Only this bundle's own script; the `/Applications` fallback is for a prompt's
        // text, not for running another copy's installer.
        guard let script = Bundle.main.path(forResource: "install-agent", ofType: "sh") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script, "skill", "setup", "--installed-only"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { _ in
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if !text.isEmpty { NSLog("Loom skill stubs: %@", text) }
        }
        do { try process.run() } catch { NSLog("Loom skill stubs: could not run %@: %@", script, "\(error)") }
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
