#!/usr/bin/env bash
# sandshell: configure Claude Code Bash guard + audit trail hooks
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/hook-post-bash.sh"
GUARD_SCRIPT="$SCRIPT_DIR/hook-pre-bash.sh"
# shellcheck source=lib/diff-apply.sh
. "$SCRIPT_DIR/lib/diff-apply.sh"

# Determine where to install — user (home dir) or project (repo) scope
SCOPE="${1:-user}"

# Accept legacy alias 'personal' → 'user'.
if [[ "$SCOPE" = "personal" ]]; then
  echo "Note: 'personal' is the legacy name for 'user' — both still accepted." >&2
  SCOPE="user"
fi

case "$SCOPE" in
  user)
    SETTINGS_DIR="$HOME/.claude"
    SETTINGS_FILE="$SETTINGS_DIR/settings.json"
    echo "Installing sandshell hooks (user scope: all projects)"
    ;;
  project)
    SETTINGS_DIR=".claude"
    SETTINGS_FILE="$SETTINGS_DIR/settings.json"
    echo "Installing sandshell hooks (project scope: this project only)"
    ;;
  --help|-h|help)
    echo "Usage: setup-hooks.sh [user|project]"
    echo ""
    echo "  user      Install to ~/.claude/settings.json (default; was 'personal' in v0.1)"
    echo "  project   Install to .claude/settings.json"
    echo ""
    echo "Legacy scope names accepted: 'personal' (alias for 'user')."
    echo ""
    echo "This configures PreToolUse/PostToolUse hooks on Bash commands."
    echo "The pre-hook blocks non-approved host commands; the post-hook logs them."
    exit 0
    ;;
  *)
    echo "Unknown scope: $SCOPE. Use 'user' or 'project'." >&2
    exit 1
    ;;
esac

# Check for jq
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for hooks. Install it:" >&2
  echo "  macOS:  brew install jq" >&2
  echo "  Linux:  apt-get install jq" >&2
  exit 1
fi

mkdir -p "$SETTINGS_DIR"

# The hooks we want to add
POST_HOOK_CONFIG=$(cat <<EOF
{
  "matcher": "Bash",
  "hooks": [
    {
      "type": "command",
      "command": "$HOOK_SCRIPT",
      "timeout": 5000
    }
  ]
}
EOF
)

PRE_HOOK_CONFIG=$(cat <<EOF
{
  "matcher": "Bash",
  "hooks": [
    {
      "type": "command",
      "command": "$GUARD_SCRIPT",
      "timeout": 5000
    }
  ]
}
EOF
)

sandshell_diff_snapshot "$SETTINGS_FILE"

if [[ -f "$SETTINGS_FILE" ]]; then
  # Check if sandshell hooks already exist
  if grep -q "hook-post-bash.sh" "$SETTINGS_FILE" 2>/dev/null && \
     grep -q "hook-pre-bash.sh" "$SETTINGS_FILE" 2>/dev/null; then
    echo "sandshell hooks already configured in $SETTINGS_FILE"
    sandshell_diff_show "$SETTINGS_FILE"
    exit 0
  fi

  # Merge into existing settings
  existing=$(cat "$SETTINGS_FILE")

  updated=$(echo "$existing" | jq \
    --argjson pre_hook "$PRE_HOOK_CONFIG" \
    --argjson post_hook "$POST_HOOK_CONFIG" '
    .hooks = (.hooks // {}) |
    .hooks.PreToolUse = (.hooks.PreToolUse // []) |
    .hooks.PostToolUse = (.hooks.PostToolUse // []) |
    if ([.hooks.PreToolUse[]?.hooks[]?.command] | index($pre_hook.hooks[0].command)) then
      .
    else
      .hooks.PreToolUse += [$pre_hook]
    end |
    if ([.hooks.PostToolUse[]?.hooks[]?.command] | index($post_hook.hooks[0].command)) then
      .
    else
      .hooks.PostToolUse += [$post_hook]
    end
  ')

  echo "$updated" | jq '.' > "$SETTINGS_FILE"
else
  # Create new settings file
  jq -n --argjson pre_hook "$PRE_HOOK_CONFIG" --argjson post_hook "$POST_HOOK_CONFIG" \
    '{"hooks": {"PreToolUse": [$pre_hook], "PostToolUse": [$post_hook]}}' > "$SETTINGS_FILE"
fi

echo ""
echo "Hooks configured in $SETTINGS_FILE"
echo ""
sandshell_diff_show "$SETTINGS_FILE"
echo ""
echo "What this does:"
echo "  - Blocks obvious sandbox-disabling Bash commands before execution"
echo "  - Logs every Bash command the agent runs on the host"
echo "  - Classifies commands (git, github_cli, sandshell, read_only, unclassified)"
echo "  - Skips direct audit-trail.sh self-logging"
echo "  - Writes to ~/.sandshell/audit/<session>.jsonl"
echo ""
echo "To remove: sandshell uninstall [user|project]"
