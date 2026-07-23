# Loom

**English** | [简体中文](README.zh-CN.md)

An **AI-operable HTTP/HTTPS debugging proxy** for macOS that lives in the status
bar. It captures traffic like Charles/Proxyman, but its primary operator is an AI
agent talking **MCP** — and the MCP surface exposes **write actions** (replay,
rules), not just read queries. The agent closes the debug loop
(capture → modify → replay → diff) while you supervise from the menu-bar panel.

## Install the plugin (Claude Code)

Loom ships as a Claude Code plugin that connects to the running app's MCP server.

```bash
claude plugin marketplace add KQAR/Loom
claude plugin install loom@loom
```

Then **launch the Loom app** (the plugin talks to it over `http://127.0.0.1:9092/mcp`).
Restart Claude Code so the `loom` MCP server connects; the agent then has 18
tools plus the `loom` skill explaining them.

> Cursor: the repo is also a Cursor plugin (`.cursor-plugin/`) — add
> `KQAR/Loom` as a plugin marketplace from Cursor's plugin settings.

## Using it over MCP

Point a client at the proxy (`curl -x http://127.0.0.1:9090 …`, the macOS system
proxy, or a phone on the same Wi-Fi via the panel's QR), then drive it from the
agent:

- **Read** — `get_recent_flows`, `get_flow_detail`, `list_devices`, `list_rules`, …
- **Write** — `replay_flow` (re-send with overrides), `create_rule` (mock / map /
  rewrite / block / delay), `set_ssl_scope`, `export_har`, …

If the tools are unreachable, the Loom app isn't running — launch it.

## Build from source

Requires [Tuist](https://tuist.io) (pinned in `mise.toml`) and Xcode (macOS 14+).

```bash
tuist install     # resolve SPM dependencies
tuist generate    # generate Loom.xcworkspace
tuist build Loom  # build the app
```

## License

MIT — see [LICENSE](LICENSE).
