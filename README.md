<p align="center">
  <img src="App/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="Loom app icon">
</p>

# Loom

**English** | [简体中文](README.zh-CN.md)

<p align="center">
  <img src="docs/assets/screenshot.png" alt="Loom main window in light and dark mode">
</p>

An **AI-operable HTTP/HTTPS debugging proxy** for macOS that lives in the status
bar. It captures traffic like Charles/Proxyman, but its primary operator is an AI
agent talking **MCP** — and the MCP surface exposes **write actions** (replay,
rules), not just read queries. The agent closes the debug loop
(capture → modify → replay → diff) while you supervise from the menu-bar panel.

## Install the app

Loom's tools are served by the running app, and the agent skill ships inside it.
Grab `Loom.dmg` from the
[latest release](https://github.com/KQAR/Loom/releases/latest), or build from
source (below).

> **First launch needs right-click → Open.** Releases are signed ad-hoc, not with
> a Developer ID certificate, so Gatekeeper blocks a plain double-click. This is a
> standing decision, not a bug: updates are authenticated by Sparkle's EdDSA
> signature instead. Subsequent launches are normal.

## Connect your agent (Claude Code / Cursor)

The agent skill ships inside the app. Run this once:

```bash
sh /Applications/Loom.app/Contents/Resources/install-agent.sh          # Claude Code
sh /Applications/Loom.app/Contents/Resources/install-agent.sh cursor   # Cursor
```

It symlinks the bundled `loom` skill into the agent's skills directory and registers
the MCP server at `http://127.0.0.1:9092/mcp`. Because the skill is a link into the
app, **updating Loom updates the skill** — there is nothing to re-install. (It also
removes the old `loom@loom` plugin if you had it.) Launch the Loom app and restart
the agent; it then has the full tool set (read + write) plus the skill explaining them.

## Using it over MCP

Point a client at the proxy (`curl -x http://127.0.0.1:9090 …`, the macOS system
proxy, or a phone on the same Wi-Fi via the panel's QR), then drive it from the
agent. A client that only understands `ALL_PROXY` gets the **SOCKS5** listener one
port up (`socks5://127.0.0.1:9091`); one that ignores proxy settings entirely
(Node's global `fetch`) gets a **reverse-proxy endpoint** — a local port standing in
for one origin (`create_reverse_proxy`).

- **Read** — `get_recent_flows`, `get_flow_detail`, `list_devices`, `list_rules`, …
- **Write** — `replay_flow` (re-send with overrides), `set_rule` (mock / map /
  rewrite / block / delay), `arm_breakpoint` + `resume` (hold traffic mid-flight
  and edit it), `set_ssl_scope`, `import_har` / `export_har`, …
- **Wait, don't poll** — `wait_for_flow` / `wait_for_pending` block until the
  traffic you triggered actually arrives.

If the tools are unreachable, the Loom app isn't running — launch it.

## Build from source

Requires [Tuist](https://tuist.io) (pinned in `mise.toml`) and Xcode (macOS 15+).

```bash
tuist install                 # resolve SPM dependencies
tuist generate                # generate Loom.xcworkspace
tuist xcodebuild -workspace Loom.xcworkspace -scheme Loom \
  -configuration Debug -destination 'platform=macOS' build
```

The `-workspace` flag is required: with only `-scheme`, xcodebuild picks the
wrong project and fails to resolve the SPM modules.

## License

MIT — see [LICENSE](LICENSE).
