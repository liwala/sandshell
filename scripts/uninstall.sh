#!/usr/bin/env bash
# sandshell: remove Claude settings/hooks and optional installed agent instructions
set -euo pipefail

usage() {
  echo "Usage: uninstall.sh [user|project] [--remove-agent-installs]"
  echo ""
  echo "Removes sandshell-managed configs across detected agents."
  echo ""
  echo "Options:"
  echo "  user                   Remove from ~/.claude, ~/.codex, ~/.gemini (default)"
  echo "  project                Remove from .claude, .gemini in cwd"
  echo "  --remove-agent-installs  Also remove installed Claude/Codex skills and"
  echo "                           generic sandshell files or sections from"
  echo "                           GEMINI.md / AGENTS.md"
  echo ""
  echo "Legacy scope names accepted: 'personal' (alias for 'user')."
  exit 0
}

SCOPE="user"
REMOVE_AGENT_INSTALLS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    user|project) SCOPE="$1"; shift ;;
    personal)
      SCOPE="user"
      echo "Note: 'personal' is the legacy name for 'user' — both still accepted." >&2
      shift
      ;;
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
  user)
    SETTINGS_DIR="$HOME/.claude"
    SETTINGS_FILE="$SETTINGS_DIR/settings.json"
    CLAUDE_SKILL_DIR="$HOME/.claude/skills/sandshell"
    CODEX_SKILL_DIR="$HOME/.codex/skills/sandshell"
    GENERIC_FILE="$HOME/.sandshell/SANDSHELL.md"
    GEMINI_FILE="$HOME/.gemini/GEMINI.md"
    # v0.2 added: agent config files written by `sandshell apply codex|gemini`
    CODEX_CONFIG="$HOME/.codex/config.toml"
    CODEX_HOOKS="$HOME/.codex/hooks.json"
    GEMINI_CONFIG="$HOME/.gemini/settings.json"
    ;;
  project)
    SETTINGS_DIR=".claude"
    SETTINGS_FILE="$SETTINGS_DIR/settings.json"
    CLAUDE_SKILL_DIR=".claude/skills/sandshell"
    CODEX_SKILL_DIR=".codex/skills/sandshell"
    GENERIC_FILE="SANDSHELL.md"
    GEMINI_FILE="GEMINI.md"
    # Codex config.toml is user-only; project scope just removes hooks.json.
    CODEX_CONFIG=""
    CODEX_HOOKS=".codex/hooks.json"
    GEMINI_CONFIG=".gemini/settings.json"
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

# Remove sandshell-managed Codex config (the file is fully sandshell-owned
# when its first comment line marks it; safest to remove the whole file).
if [[ -n "$CODEX_CONFIG" && -f "$CODEX_CONFIG" ]]; then
  if grep -q "Managed by sandshell" "$CODEX_CONFIG" 2>/dev/null; then
    rm "$CODEX_CONFIG"
    echo "Removed sandshell-managed $CODEX_CONFIG"
  else
    # Mixed config: strip just the codex_hooks feature flag we added.
    if grep -qE '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true' "$CODEX_CONFIG"; then
      sed -i.bak -E '/^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true[[:space:]]*$/d' "$CODEX_CONFIG"
      rm -f "$CODEX_CONFIG.bak"
      echo "Removed codex_hooks feature flag from $CODEX_CONFIG"
    fi
  fi
fi

# Remove sandshell-installed hooks from ~/.codex/hooks.json (or
# .codex/hooks.json at project scope). Surgical jq remove — preserves any
# user-added hooks for other tools.
if [[ -n "$CODEX_HOOKS" && -f "$CODEX_HOOKS" ]]; then
  updated=$(jq '
    .hooks.PreToolUse = ((.hooks.PreToolUse // []) |
      map(select(([(.hooks[]?.command // empty)] | any(contains("hook-pre-bash.sh"))) | not))) |
    .hooks.PostToolUse = ((.hooks.PostToolUse // []) |
      map(select(([(.hooks[]?.command // empty)] | any(contains("hook-post-bash.sh"))) | not))) |
    if (.hooks.PreToolUse // [] | length) == 0 then del(.hooks.PreToolUse) else . end |
    if (.hooks.PostToolUse // [] | length) == 0 then del(.hooks.PostToolUse) else . end |
    if (.hooks // {}) == {} then del(.hooks) else . end
  ' "$CODEX_HOOKS")
  if [[ "$(echo "$updated" | jq 'length')" == "0" ]]; then
    rm "$CODEX_HOOKS"
    echo "Removed empty $CODEX_HOOKS"
  else
    printf '%s\n' "$updated" | jq '.' > "$CODEX_HOOKS"
    echo "Removed sandshell hooks from $CODEX_HOOKS"
  fi
fi

# Remove sandshell-managed sections from Gemini settings — preserves any
# unrelated keys the user added (preserves the symmetry with Claude's removal
# pattern, which only deletes sandbox/permissions/hooks added by sandshell).
if [[ -n "$GEMINI_CONFIG" && -f "$GEMINI_CONFIG" ]]; then
  if jq -e '.sandshell_managed == true' "$GEMINI_CONFIG" >/dev/null 2>&1; then
    updated=$(jq '
      del(.sandshell_managed) |
      .tools = (.tools // {} | del(.sandbox, .sandboxNetworkAccess)) |
      if (.tools // {}) == {} then del(.tools) else . end |
      .security = (.security // {} | del(.folderTrust, .disableYoloMode, .disableAlwaysAllow)) |
      if (.security // {}) == {} then del(.security) else . end |
      .general = (.general // {} | del(.defaultApprovalMode)) |
      if (.general // {}) == {} then del(.general) else . end
    ' "$GEMINI_CONFIG")
    if [[ "$(echo "$updated" | jq 'length')" == "0" ]]; then
      rm "$GEMINI_CONFIG"
      echo "Removed empty $GEMINI_CONFIG"
    else
      printf '%s\n' "$updated" | jq '.' > "$GEMINI_CONFIG"
      echo "Removed sandshell-managed sections from $GEMINI_CONFIG"
    fi
  fi
fi

if [[ "$REMOVE_AGENT_INSTALLS" = true ]]; then
  rm -rf "$CLAUDE_SKILL_DIR" "$CODEX_SKILL_DIR"
  rm -f "$GENERIC_FILE"
  strip_marked_section "$GEMINI_FILE"
  strip_marked_section "$AMP_FILE"
  echo "Removed sandshell-installed agent instructions for scope: $SCOPE"
fi

echo "Rollback complete."
