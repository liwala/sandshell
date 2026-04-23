#!/usr/bin/env bash
# sandshell: configure Claude Code Bash guard + audit trail hooks
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/hook-post-bash.sh"
GUARD_SCRIPT="$SCRIPT_DIR/hook-pre-bash.sh"

# Determine where to install — personal or project scope
SCOPE="${1:-personal}"

case "$SCOPE" in
  personal)
    SETTINGS_DIR="$HOME/.claude"
    SETTINGS_FILE="$SETTINGS_DIR/settings.json"
    echo "Installing sandshell hooks (personal scope: all projects)"
    ;;
  project)
    SETTINGS_DIR=".claude"
    SETTINGS_FILE="$SETTINGS_DIR/settings.json"
    echo "Installing sandshell hooks (project scope: this project only)"
    ;;
  --help|-h|help)
    echo "Usage: setup-hooks.sh [personal|project]"
    echo ""
    echo "  personal  Install to ~/.claude/settings.json (default)"
    echo "  project   Install to .claude/settings.json"
    echo ""
    echo "This configures PreToolUse/PostToolUse hooks on Bash commands."
    echo "The pre-hook blocks non-approved host commands; the post-hook logs them."
    exit 0
    ;;
  *)
    echo "Unknown scope: $SCOPE. Use 'personal' or 'project'." >&2
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

if [[ -f "$SETTINGS_FILE" ]]; then
  # Check if sandshell hooks already exist
  if grep -q "hook-post-bash.sh" "$SETTINGS_FILE" 2>/dev/null && \
     grep -q "hook-pre-bash.sh" "$SETTINGS_FILE" 2>/dev/null; then
    echo "sandshell hooks already configured in $SETTINGS_FILE"
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
echo "What this does:"
echo "  - Blocks obvious sandbox-disabling Bash commands before execution"
echo "  - Logs every Bash command the agent runs on the host"
echo "  - Classifies commands (git, github_cli, sandshell, read_only, unclassified)"
echo "  - Skips direct audit.sh self-logging"
echo "  - Writes to ~/.sandshell/audit/<session>.jsonl"
echo ""
echo "To remove, edit $SETTINGS_FILE and delete the sandshell PreToolUse/PostToolUse entries."
