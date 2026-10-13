#!/bin/sh
# Connect an agent to this copy of Loom, once.
#
#   sh /Applications/Loom.app/Contents/Resources/install-agent.sh [claude|cursor]...
#
# The skill is *linked* into the app bundle rather than copied, so it is always the
# one that ships with the running app: a Sparkle update replaces the bundle in place
# and the agent reads the new skill on its next session, with nothing to re-install.
# The MCP endpoint is a fixed loopback URL, so registering it once is enough.
#
# Replaces the old `loom@loom` plugin, which carried its own copy of the skill and
# went stale on every app update until someone ran `/plugin update`; it is removed
# here, or the agent would see two `loom` skills and two `loom` servers.
#
# Re-run it after moving Loom.app — the link points at wherever this script is.
set -eu

res=$(cd "$(dirname "$0")" && pwd -P)
skill="$res/skills/loom"
[ -f "$skill/SKILL.md" ] || { echo "no bundled skill at $skill" >&2; exit 1; }

url="http://127.0.0.1:9092/mcp"
# 120 s, because `wait_for_flow` / `wait_for_pending` block for up to 60 s and an
# unconfigured client gives an HTTP server 60 s to produce its first byte.
server="{\"type\":\"http\",\"url\":\"$url\",\"timeout\":120000}"

link_skill() {
  dir=$1
  mkdir -p "$dir"
  if [ -e "$dir/loom" ] && [ ! -L "$dir/loom" ]; then
    echo "$dir/loom exists and is not a link — move it aside and re-run" >&2
    exit 1
  fi
  ln -sfn "$skill" "$dir/loom"
  echo "skill: $dir/loom -> $skill"
}

install_claude() {
  command -v claude >/dev/null || { echo "claude CLI not found on PATH" >&2; exit 1; }
  claude plugin uninstall loom@loom >/dev/null 2>&1 && echo "removed the old loom@loom plugin" || true
  claude plugin marketplace remove loom >/dev/null 2>&1 || true
  link_skill "$HOME/.claude/skills"
  claude mcp remove --scope user loom >/dev/null 2>&1 || true
  claude mcp add-json --scope user loom "$server" >/dev/null
  echo "mcp: loom -> $url (user scope)"
}

install_cursor() {
  link_skill "$HOME/.cursor/skills"
  config="$HOME/.cursor/mcp.json"
  mkdir -p "$HOME/.cursor"
  # plutil edits JSON in place, but reads a bare `{}` as OpenStep and refuses it —
  # so an absent or empty config is written fresh, and anything else is edited.
  if [ ! -s "$config" ] || [ "$(tr -d ' \n\t' < "$config")" = "{}" ]; then
    echo '{"mcpServers":{}}' > "$config"
  elif ! plutil -extract mcpServers json -o /dev/null "$config" 2>/dev/null; then
    plutil -insert mcpServers -json '{}' "$config"
  fi
  plutil -replace mcpServers.loom -json "$server" "$config"
  echo "mcp: loom -> $url ($config)"
}

[ $# -gt 0 ] || set -- claude
for target in "$@"; do
  case $target in
    claude) install_claude ;;
    cursor) install_cursor ;;
    *) echo "unknown target: $target (claude | cursor)" >&2; exit 2 ;;
  esac
done
echo "done — restart the agent so it picks up the skill and the server."
