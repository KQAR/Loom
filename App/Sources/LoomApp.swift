import AppFeature
import ComposableArchitecture
import MCPServer
import PrivilegedHelperClient
import LoomProxyCore
import SwiftUI

@main
struct LoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let store = Store(initialState: AppFeature.State()) {
        AppFeature()
    }
    // `routing` is what lets an agent see *and* fix "nothing is pointed at the
    // proxy" — client-layer capability the engine can't reach, injected here.
    private let mcp = MCPServer(
        engine: ProxyEngine.shared, appVersion: appVersion, routing: SystemRoutingAdapter()
    )

    init() {
        // Claim the MCP port before *either* listener starts — synchronously, because
        // this is the race it exists to prevent: a reverse-proxy endpoint persisted on
        // 9092 gets bound during the engine's start, and if it wins, Loom comes up with
        // its whole control plane unreachable. The engine refuses its own two ports by
        // number, but it must not know what an MCP server is, so the number is declared
        // from here (see `ReservedPorts`).
        ReservedPorts.shared.reserve(MCPServer.defaultPort, holder: "Loom's MCP control port")
        // The proxy is started by AppFeature's one-shot boot effect (fired by the
        // always-present menu-bar label at launch) — the single start owner, so we
        // don't race a second bind here. The MCP server is independent; start it.
        let mcp = self.mcp
        Task {
            do {
                // Fixed loopback port so the Claude Code plugin's HTTP MCP config
                // (http://127.0.0.1:9092/mcp) can reach it without discovery.
                let port = try await mcp.start(port: MCPServer.defaultPort)
                NSLog("Loom MCP server listening on 127.0.0.1:\(port)")
            } catch {
                NSLog("Loom MCP server failed to start: \(error.localizedDescription)")
            }
        }
    }

    var body: some Scene {
        // Status bar: compact config & control console.
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        // Main window: the request list + detail (the working surface).
        //
        // `.hiddenTitleBar` because DESIGN.md's main-window structure says "no
        // sidebar/window title": the toolbar already carries the address chip and
        // the capture controls, and a centred "Loom" above the sidebar repeats what
        // the menu-bar icon and the app itself have already said. The window still
        // needs a *name* — it is what `openWindow(id:)` restores and what the
        // Window menu lists — so the title stays on the scene and only its
        // presentation is hidden. Toolbar items are unaffected; they move into the
        // unified bar.
        Window("Loom", id: "main") {
            MainView(store: store)
        }
        .defaultSize(width: 1040, height: 640)
        .windowStyle(.hiddenTitleBar)
    }
}

private let appVersion: String =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"

/// Quit-time cleanup: if the system proxy still routes through Loom, turn it
/// off before the process dies — otherwise every app on the machine keeps
/// sending traffic to a dead port. (A crash skips this; the boot-time state
/// sync in `AppFeature` then shows the stale override so the human can act.)
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Single-instance guard. Runs before the scene renders (so before the
    /// menu-bar label's boot `.task` starts the proxy) and before MCP binds its
    /// fixed port. If another Loom is already running under the same bundle id —
    /// a second `/Applications` copy, a stray dev build from a git worktree, a
    /// double double-click — hand focus to it and `exit(0)` immediately.
    ///
    /// We use `exit(0)`, NOT `NSApp.terminate`, on purpose: terminate would run
    /// `applicationShouldTerminate` below, whose cleanup turns off the system
    /// proxy — but that proxy belongs to the *first* instance, so tearing it
    /// down here would break the live one. A duplicate must die without touching
    /// any shared system state.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        guard let existing = others.first else { return }
        existing.activate()
        NSLog("Loom: another instance (pid \(existing.processIdentifier)) is already running — exiting.")
        exit(0)
    }

    /// Clear a QUIC (pf) block that outlived the session that created it.
    ///
    /// The quit path below removes the block along with the proxy, but a crash skips
    /// it. What's left is worse than a stale proxy setting: the pf anchor drops *all*
    /// outbound UDP/443 machine-wide, and no UI path could undo it — the panel's
    /// toggle only runs the enable branch while the proxy is off, so the pf restore
    /// was unreachable and the user's only escape was `sudo pfctl -f /etc/pf.conf`.
    ///
    /// A no-op unless a block is actually recorded *and* the proxy no longer points
    /// at Loom, so the common launch costs nothing and shows no prompt.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let helper = PrivilegedHelperClient.liveValue
        Task.detached {
            let port = await ProxyEngine.shared.status().port
            if await helper.restoreOrphanedQUICBlock(port) {
                NSLog("Loom: cleared a QUIC firewall block left over from a previous session.")
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let helper = PrivilegedHelperClient.liveValue
        Task.detached {
            let port = await ProxyEngine.shared.status().port
            if await helper.isSystemProxyActive(port) {
                _ = await helper.setSystemProxy(false, port)
            }
            // Drain the flow-persistence write queue before we die: completed
            // flows are saved fire-and-forget, so a quit could otherwise outrun
            // the last few writes.
            await ProxyEngine.shared.flushFlows()
            await MainActor.run {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

/// Menu-bar icon with state variants. The glyph is Loom's own mark (a custom SF
/// Symbol, see DESIGN.md § Brand mark): an outlined window on a bus with a node
/// where it meets the line. The node carries the rules state — it solidifies when
/// traffic is being acted on — so one glyph covers both states:
/// - stopped → dimmed
/// - running, no map rules → `loom.mark` (hollow node)
/// - running, map/rewrite active → `loom.mark.intercept` (solid node)
/// Also the always-present surface that boots the capture subscription at launch.
private struct MenuBarLabel: View {
    let store: StoreOf<AppFeature>
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(store.rules.rulesEnabled ? "loom.mark.intercept" : "loom.mark")
            .fontWeight(.semibold)
            .foregroundStyle(store.setup.isSystemProxy ? Color.yellow : Color.primary)
            .opacity(store.status.isRunning ? 1 : 0.4)
            .task {
                store.send(.task)
                // Open the main window on launch so the app presents its working
                // surface by default (it's a Dock-less menu-bar app; without this
                // the human would have to open the window from the panel first).
                // `.task` runs once for this always-present label, and `Window` is a
                // singleton scene, so this opens exactly one main window.
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
    }
}
