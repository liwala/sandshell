#!/usr/bin/env bash
# sandshell: configure Claude Code hooks for audit trail
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/hook-post-bash.sh"

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
    echo "This configures a PostToolUse hook on Bash commands that logs"
    echo "all host-side commands to the sandshell audit trail."
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

# The hook config we want to add
HOOK_CONFIG=$(cat <<EOF
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

if [[ -f "$SETTINGS_FILE" ]]; then
  # Check if sandshell hook already exists
  if grep -q "hook-post-bash.sh" "$SETTINGS_FILE" 2>/dev/null; then
    echo "sandshell hooks already configured in $SETTINGS_FILE"
    exit 0
  fi

  # Merge into existing settings
  existing=$(cat "$SETTINGS_FILE")

  # Check if PostToolUse array exists
  if echo "$existing" | jq -e '.hooks.PostToolUse' >/dev/null 2>&1; then
    # Append to existing PostToolUse array
    updated=$(echo "$existing" | jq --argjson hook "$HOOK_CONFIG" \
      '.hooks.PostToolUse += [$hook]')
  elif echo "$existing" | jq -e '.hooks' >/dev/null 2>&1; then
    # hooks exists but no PostToolUse
    updated=$(echo "$existing" | jq --argjson hook "$HOOK_CONFIG" \
      '.hooks.PostToolUse = [$hook]')
  else
    # No hooks at all
    updated=$(echo "$existing" | jq --argjson hook "$HOOK_CONFIG" \
      '.hooks = {"PostToolUse": [$hook]}')
  fi

  echo "$updated" | jq '.' > "$SETTINGS_FILE"
else
  # Create new settings file
  jq -n --argjson hook "$HOOK_CONFIG" \
    '{"hooks": {"PostToolUse": [$hook]}}' > "$SETTINGS_FILE"
fi

echo ""
echo "Hooks configured in $SETTINGS_FILE"
echo ""
echo "What this does:"
echo "  - Logs every Bash command the agent runs on the host"
echo "  - Classifies commands (git, github_cli, container_mgmt, read_only, unclassified)"
echo "  - Skips commands already logged by sandbox.sh/harden.sh"
echo "  - Writes to ~/.sandshell/audit/<session>.jsonl"
echo ""
echo "To remove, edit $SETTINGS_FILE and delete the sandshell PostToolUse entry."
