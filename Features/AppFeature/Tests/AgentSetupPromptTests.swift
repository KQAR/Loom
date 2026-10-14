@testable import AppFeature
import Foundation
import Testing

@Suite struct AgentSetupPromptTests {
    /// The prompt is pasted into an agent that will run it, so the path must survive
    /// the shell whatever folder Loom was dragged into.
    @Test func namesThisCopysInstallerQuotedForBothAgents() {
        let text = AgentSetupPrompt.text(scriptPath: "/Users/me/My Apps/Loom.app/Contents/Resources/install-agent.sh")
        #expect(text.contains("sh '/Users/me/My Apps/Loom.app/Contents/Resources/install-agent.sh' claude"))
        #expect(text.contains("sh '/Users/me/My Apps/Loom.app/Contents/Resources/install-agent.sh' cursor"))
    }

    @Test func aQuoteInThePathCannotEndTheQuoting() throws {
        let quoted = AgentSetupPrompt.shellQuoted("/tmp/it's/install-agent.sh")
        #expect(quoted == #"'/tmp/it'\''s/install-agent.sh'"#)

        // …and a real shell reads it back as the one path.
        let echo = Process()
        echo.executableURL = URL(fileURLWithPath: "/bin/sh")
        echo.arguments = ["-c", "printf %s \(quoted)"]
        let out = Pipe()
        echo.standardOutput = out
        try echo.run()
        echo.waitUntilExit()
        let read = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(read == "/tmp/it's/install-agent.sh")
    }
}
