import AppFeature
import ComposableArchitecture
import MCPServer
import PrivilegedHelperClient
import ProxyCore
import SwiftUI

@main
struct LoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let store = Store(initialState: AppFeature.State()) {
        AppFeature()
    }
    private let mcp = MCPServer(engine: ProxyEngine.shared, appVersion: appVersion)

    init() {
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
        Window("Loom", id: "main") {
            MainView(store: store)
        }
        .defaultSize(width: 1040, height: 640)
    }
}

private let appVersion: String =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"

/// Quit-time cleanup: if the system proxy still routes through Loom, turn it
/// off before the process dies — otherwise every app on the machine keeps
/// sending traffic to a dead port. (A crash skips this; the boot-time state
/// sync in `AppFeature` then shows the stale override so the human can act.)
final class AppDelegate: NSObject, NSApplicationDelegate {
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

/// Menu-bar icon with state variants:
/// - stopped → dimmed
/// - running, no map rules → two-way arrows
/// - running, map/rewrite active → branch glyph
/// Also the always-present surface that boots the capture subscription at launch.
private struct MenuBarLabel: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        Image(systemName: store.rules.rulesEnabled ? "arrow.triangle.branch" : "arrow.left.arrow.right")
            .fontWeight(.semibold)
            .foregroundStyle(store.setup.isSystemProxy ? Color.yellow : Color.primary)
            .opacity(store.status.isRunning ? 1 : 0.4)
            .task { store.send(.task) }
    }
}
