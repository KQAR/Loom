#!/bin/sh
# Connect an agent to this copy of Loom, once.
#
#   sh /Applications/Loom.app/Contents/Resources/install-agent.sh [claude|cursor]...
#   sh /Applications/Loom.app/Contents/Resources/install-agent.sh skill setup|status|remove
#
# What lands in an agent's skills directory is a stub of a few hundred bytes: the
# skill's own name and description (so the agent decides to load it exactly as it
# would the full guide) and one instruction — call the `get_skill_guide` tool on the
# `loom` MCP server. The guide itself is served by the running app, so it always
# describes the tools that app serves, and the stub holds no path into a bundle:
# moving, deleting or running Loom from its DMG cannot leave it dangling, which the
# symlink this replaces could. The app refreshes an outdated stub at launch, so a
# Sparkle update carries its stub along.
#
# Directories: Claude Code reads ~/.claude/skills; Codex, OpenCode, Pi and Cursor
# share ~/.agents/skills, written once for all of them. Only a SKILL.md carrying
# the `loom-stub` marker is ever rewritten or removed — anything else is someone
# else's file. An old symlink into a Loom.app bundle is migrated.
#
# Replaces the old `loom@loom` plugin too, which carried its own copy of the skill;
# it is removed here, or the agent would see two `loom` skills and two servers.
set -eu

res=$(cd "$(dirname "$0")" && pwd -P)
guide="$res/skills/loom/SKILL.md"
[ -f "$guide" ] || { echo "no bundled skill at $guide" >&2; exit 1; }

url="http://127.0.0.1:9092/mcp"
# 120 s, because `wait_for_flow` / `wait_for_pending` block for up to 60 s and an
# unconfigured client gives an HTTP server 60 s to produce its first byte.
server="{\"type\":\"http\",\"url\":\"$url\",\"timeout\":120000}"

# --- skill stub -----------------------------------------------------------------

# The stub's shape version; `status` compares the whole file anyway.
stub_version=1

stub() {
  echo "---"
  # The guide's frontmatter: everything between its first two `---` lines.
  awk 'NR == 1 && /^---$/ { f = 1; next } f && /^---$/ { exit } f' "$guide"
  cat <<EOF
metadata:
  loom-stub: "$stub_version"
---
<!-- Installed by Loom's install-agent.sh. Remove it with "install-agent.sh skill remove". -->

Call the \`get_skill_guide\` tool of the \`loom\` MCP server (no arguments) and
follow the guide it returns. It comes from the running Loom app, so it describes
the tools that app serves. It names deeper topics; read one with
\`get_skill_guide\` and \`topic\`.

If no \`loom\` tools are available, do not invent data:
- Loom is not running: ask the user to launch it (\`open -b com.loom.app\`), or to
  install it from https://github.com/KQAR/Loom.
- Or the server is not registered with you: it is an HTTP MCP server at
  \`$url\`. For Claude Code or Cursor,
  \`sh /Applications/Loom.app/Contents/Resources/install-agent.sh [claude|cursor]\`
  registers it (Loom ▸ Copy Agent Setup Prompt gives the installed copy's path).
EOF
}

# agents|directory under $HOME|legacy symlink under $HOME|markers under $HOME
targets() {
  echo "Claude Code|.claude/skills/loom|.claude/skills/loom|.claude"
  # Cursor is in the shared row on evidence: its agent always loads ~/.cursor/skills
  # and ~/.agents/skills, so a third copy would only be one it already reads. Its old
  # link in ~/.cursor/skills is what migrates here.
  echo "Codex, OpenCode, Pi, Cursor|.agents/skills/loom|.cursor/skills/loom|.codex .config/opencode .pi .cursor .agents"
}

tilde() { echo "~/$1"; }

# A symlink into some Loom.app's bundled skill — what this script used to install.
is_loom_link() {
  [ -L "$1" ] && case $(readlink "$1") in */Contents/Resources/skills/loom) true ;; *) false ;; esac
}

detected() {
  for m in $1; do [ -e "$HOME/$m" ] && return 0; done
  return 1
}

state() {  # dir legacy
  if is_loom_link "$HOME/$2"; then echo legacy; return; fi
  if [ -L "$HOME/$1" ]; then echo foreign; return; fi
  file="$HOME/$1/SKILL.md"
  if [ ! -f "$file" ]; then echo missing
  elif stub | cmp -s - "$file"; then echo current
  elif grep -q '^  loom-stub:' "$file"; then echo outdated
  else echo foreign
  fi
}

write_stub() {  # dir legacy
  if is_loom_link "$HOME/$2"; then rm "$HOME/$2"; fi
  mkdir -p "$HOME/$1"
  stub > "$HOME/$1/SKILL.md.tmp"
  mv "$HOME/$1/SKILL.md.tmp" "$HOME/$1/SKILL.md"
}

skill_setup() {
  installed_only=${1-}
  found=0
  while IFS='|' read -r agents dir legacy markers; do
    s=$(state "$dir" "$legacy")
    if [ "$installed_only" = --installed-only ]; then
      # What the app runs at launch: refresh what is there, install nothing new.
      case $s in outdated|legacy) write_stub "$dir" "$legacy"; echo "refreshed   $(tilde "$dir")" ;; esac
      continue
    fi
    detected "$markers" || continue
    found=1
    case $s in
      current) echo "up to date  $(tilde "$dir")  ($agents)" ;;
      foreign) echo "skipped     $(tilde "$dir")  (a SKILL.md not written by Loom is there; remove it to install)" ;;
      *) write_stub "$dir" "$legacy"; echo "wrote       $(tilde "$dir")  ($agents)" ;;
    esac
  done <<EOF
$(targets)
EOF
  if [ "$installed_only" != --installed-only ] && [ $found = 0 ]; then
    echo "no supported agent found (looked for ~/.claude, ~/.codex, ~/.config/opencode, ~/.pi, ~/.cursor, ~/.agents)"
  fi
}

skill_status() {
  while IFS='|' read -r agents dir legacy markers; do
    if detected "$markers"; then f=found; else f="not found"; fi
    echo "$agents ($f)"
    printf '  skill  %-9s %s\n' "$(state "$dir" "$legacy")" "$(tilde "$dir")"
  done <<EOF
$(targets)
EOF
}

skill_remove() {
  while IFS='|' read -r agents dir legacy markers; do
    case $(state "$dir" "$legacy") in
      legacy) rm "$HOME/$legacy"; echo "removed     $(tilde "$legacy")  (old link)" ;;
      current|outdated)
        rm "$HOME/$dir/SKILL.md"
        rmdir "$HOME/$dir" 2>/dev/null || true  # leave it if something else is in it
        echo "removed     $(tilde "$dir")" ;;
    esac
  done <<EOF
$(targets)
EOF
}

# --- MCP registration -----------------------------------------------------------

install_claude() {
  command -v claude >/dev/null || { echo "claude CLI not found on PATH" >&2; exit 1; }
  claude plugin uninstall loom@loom >/dev/null 2>&1 && echo "removed the old loom@loom plugin" || true
  claude plugin marketplace remove loom >/dev/null 2>&1 || true
  claude mcp remove --scope user loom >/dev/null 2>&1 || true
  claude mcp add-json --scope user loom "$server" >/dev/null
  echo "mcp: loom -> $url (user scope)"
}

install_cursor() {
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

if [ "${1-}" = skill ]; then
  case ${2-} in
    setup) skill_setup "${3-}" ;;
    status) skill_status ;;
    remove) skill_remove ;;
    *) echo "usage: install-agent.sh skill setup|status|remove" >&2; exit 2 ;;
  esac
  exit 0
fi

[ $# -gt 0 ] || set -- claude
for target in "$@"; do
  case $target in
    claude) install_claude ;;
    cursor) install_cursor ;;
    *) echo "unknown target: $target (claude | cursor | skill)" >&2; exit 2 ;;
  esac
done
skill_setup
echo "done — restart the agent so it picks up the skill and the server."
