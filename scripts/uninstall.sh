#!/usr/bin/env bash
# sandshell: remove Claude settings/hooks and optional installed agent instructions
set -euo pipefail

usage() {
  echo "Usage: uninstall.sh [personal|project] [--remove-agent-installs]"
  echo ""
  echo "Removes sandshell-managed Claude settings and hooks."
  echo ""
  echo "Options:"
  echo "  personal               Remove from ~/.claude/settings.json (default)"
  echo "  project                Remove from .claude/settings.json"
  echo "  --remove-agent-installs  Also remove installed Claude/Codex skills and"
  echo "                           sandshell sections from GEMINI.md / AGENTS.md"
  exit 0
}

SCOPE="personal"
REMOVE_AGENT_INSTALLS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    personal|project) SCOPE="$1"; shift ;;
    --remove-agent-installs) REMOVE_AGENT_INSTALLS=true; shift ;;
    --help|-h|help) usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for uninstall. Install it:" >&2
  echo "  macOS:  brew install jq" >&2
  echo "  Linux:  apt-get install jq" >&2
  exit 1
fi

strip_marked_section() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/sandshell-uninstall.XXXXXX")
  awk '
    /<!-- sandshell: begin -->/ { skip=1; next }
    /<!-- sandshell: end -->/   { skip=0; next }
    !skip { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

case "$SCOPE" in
  personal)
    SETTINGS_DIR="$HOME/.claude"
    SETTINGS_FILE="$SETTINGS_DIR/settings.json"
    CLAUDE_SKILL_DIR="$HOME/.claude/skills/sandshell"
    CODEX_SKILL_DIR="$HOME/.codex/skills/sandshell"
    GEMINI_FILE="$HOME/.gemini/GEMINI.md"
    ;;
  project)
    SETTINGS_DIR=".claude"
    SETTINGS_FILE="$SETTINGS_DIR/settings.json"
    CLAUDE_SKILL_DIR=".claude/skills/sandshell"
    CODEX_SKILL_DIR=".codex/skills/sandshell"
    GEMINI_FILE="GEMINI.md"
    ;;
esac
AMP_FILE="AGENTS.md"

if [[ -f "$SETTINGS_FILE" ]]; then
  updated=$(jq '
    del(.sandshell_managed) |
    del(.sandbox) |
    .permissions.deny = ((.permissions.deny // []) | map(select(. != "Bash(dangerouslyDisableSandbox:true)"))) |
    if (.permissions.deny | length) == 0 then del(.permissions.deny) else . end |
    if (.permissions // {}) == {} then del(.permissions) else . end |
    .hooks.PreToolUse = ((.hooks.PreToolUse // []) |
      map(select(([(.hooks[]?.command // empty)] | any(contains("hook-pre-bash.sh"))) | not))) |
    .hooks.PostToolUse = ((.hooks.PostToolUse // []) |
      map(select(([(.hooks[]?.command // empty)] | any(contains("hook-post-bash.sh"))) | not))) |
    if (.hooks.PreToolUse // [] | length) == 0 then del(.hooks.PreToolUse) else . end |
    if (.hooks.PostToolUse // [] | length) == 0 then del(.hooks.PostToolUse) else . end |
    if (.hooks // {}) == {} then del(.hooks) else . end
  ' "$SETTINGS_FILE")

  printf '%s\n' "$updated" | jq '.' > "$SETTINGS_FILE"
  echo "Removed sandshell-managed settings from $SETTINGS_FILE"
else
  echo "No Claude settings file found at $SETTINGS_FILE"
fi

if [[ "$REMOVE_AGENT_INSTALLS" = true ]]; then
  rm -rf "$CLAUDE_SKILL_DIR" "$CODEX_SKILL_DIR"
  strip_marked_section "$GEMINI_FILE"
  strip_marked_section "$AMP_FILE"
  echo "Removed sandshell-installed agent instructions for scope: $SCOPE"
fi

echo "Rollback complete."
