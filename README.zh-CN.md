# Loom

[English](README.md) | **简体中文**

一个常驻状态栏的 **AI 可操作 HTTP/HTTPS 调试代理**(macOS)。它像 Charles/Proxyman
一样抓包,但主要的操作者是通过 **MCP** 对话的 AI Agent——而且 MCP 暴露的是**写操作**
(重放、规则),不只是只读查询。Agent 由此闭合调试环(抓包 → 改写 → 重放 → 对比),
你则从菜单栏面板监督。

## 安装插件(Claude Code)

Loom 以 Claude Code 插件形式分发,连接到运行中的 App 的 MCP 服务。

```bash
claude plugin marketplace add KQAR/Loom
claude plugin install loom@loom
```

然后**启动 Loom App**(插件通过 `http://127.0.0.1:9092/mcp` 与它通信)。重启 Claude Code
让 `loom` MCP 服务连上;之后 Agent 即可使用 18 个工具,以及讲解用法的 `loom` skill。

> Cursor:本仓库同时是 Cursor 插件(`.cursor-plugin/`)——在 Cursor 的插件设置里把
> `KQAR/Loom` 添加为插件 marketplace 即可。

## 通过 MCP 使用

先让客户端走代理(`curl -x http://127.0.0.1:9090 …`、macOS 系统代理,或同一 Wi-Fi 下
的手机扫面板二维码),再由 Agent 驱动:

- **读** — `get_recent_flows`、`get_flow_detail`、`list_devices`、`list_rules` …
- **写** — `replay_flow`(带改写重放)、`create_rule`(mock / 映射 / 改写 / 拦截 / 延迟)、
  `set_ssl_scope`、`export_har` …

若工具连不上,说明 Loom App 没有运行——启动它即可。

## 从源码构建

需要 [Tuist](https://tuist.io)(版本锁定在 `mise.toml`)和 Xcode(macOS 14+)。

```bash
tuist install     # 解析 SPM 依赖
tuist generate    # 生成 Loom.xcworkspace
tuist build Loom  # 构建 App
```

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
