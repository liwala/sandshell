#!/usr/bin/env bash
# sandshell: configure Codex CLI Bash guard + audit trail hooks.
#
# Codex's hook model mirrors Claude Code's almost 1:1 — same event names
# (PreToolUse, PostToolUse, …), same JSON-on-stdin input shape, same
# exit-code semantics (0 = continue, 2 = block, JSON for structured
# response). Reference: developers.openai.com/codex/hooks.
#
# We reuse the same hook-pre-bash.sh / hook-post-bash.sh scripts for both
# agents. Codex hooks are gated behind a feature flag in config.toml;
# this script flips it on at user scope (where features apply globally).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/hook-post-bash.sh"
GUARD_SCRIPT="$SCRIPT_DIR/hook-pre-bash.sh"
# shellcheck source=lib/diff-apply.sh
. "$SCRIPT_DIR/lib/diff-apply.sh"

SCOPE="${1:-user}"

# Accept legacy alias 'workspace' → 'project'.
if [[ "$SCOPE" = "workspace" ]]; then
  echo "Note: 'workspace' is the legacy name for 'project' — both still accepted." >&2
  SCOPE="project"
fi

case "$SCOPE" in
  user)
    HOOKS_DIR="$HOME/.codex"
    HOOKS_FILE="$HOOKS_DIR/hooks.json"
    echo "Installing sandshell hooks for Codex (user scope: all projects)"
    ;;
  project)
    HOOKS_DIR=".codex"
    HOOKS_FILE="$HOOKS_DIR/hooks.json"
    echo "Installing sandshell hooks for Codex (project scope: this project only)"
    ;;
  --help | -h | help)
    cat << EOF
Usage: setup-codex-hooks.sh [user|project]

  user      Install to ~/.codex/hooks.json (default)
  project   Install to .codex/hooks.json in cwd

Configures PreToolUse/PostToolUse hooks for Codex Bash commands. The
pre-hook blocks obvious sandbox-disable attempts; the post-hook logs every
command into the shared sandshell audit trail at ~/.sandshell/audit/.

Always enables the [features] codex_hooks = true flag in
~/.codex/config.toml (the gate for Codex hook execution). Without that
flag, Codex ignores hooks.json silently.
EOF
    exit 0
    ;;
  *)
    echo "Unknown scope: $SCOPE. Use 'user' or 'project'." >&2
    exit 1
    ;;
esac

if ! command -v jq > /dev/null 2>&1; then
  echo "ERROR: jq is required for hooks." >&2
  exit 1
fi

mkdir -p "$HOOKS_DIR"

# Hook entries. Codex matchers are regex (per docs); ^Bash$ is exact.
PRE_HOOK_CONFIG=$(
  cat << EOF
{
  "matcher": "^Bash$",
  "hooks": [{"type": "command", "command": "$GUARD_SCRIPT", "timeout": 5000}]
}
EOF
)

POST_HOOK_CONFIG=$(
  cat << EOF
{
  "matcher": "^Bash$",
  "hooks": [{"type": "command", "command": "$HOOK_SCRIPT", "timeout": 5000}]
}
EOF
)

sandshell_diff_snapshot "$HOOKS_FILE"

if [[ -f "$HOOKS_FILE" ]]; then
  if grep -q "hook-post-bash.sh" "$HOOKS_FILE" 2> /dev/null \
    && grep -q "hook-pre-bash.sh" "$HOOKS_FILE" 2> /dev/null; then
    echo "sandshell hooks already configured in $HOOKS_FILE"
  else
    existing=$(cat "$HOOKS_FILE")
    updated=$(echo "$existing" | jq \
      --argjson pre "$PRE_HOOK_CONFIG" \
      --argjson post "$POST_HOOK_CONFIG" '
      .hooks = (.hooks // {}) |
      .hooks.PreToolUse = (.hooks.PreToolUse // []) |
      .hooks.PostToolUse = (.hooks.PostToolUse // []) |
      if ([.hooks.PreToolUse[]?.hooks[]?.command] | index($pre.hooks[0].command)) then . else .hooks.PreToolUse += [$pre] end |
      if ([.hooks.PostToolUse[]?.hooks[]?.command] | index($post.hooks[0].command)) then . else .hooks.PostToolUse += [$post] end
    ')
    echo "$updated" | jq '.' > "$HOOKS_FILE"
  fi
else
  jq -n --argjson pre "$PRE_HOOK_CONFIG" --argjson post "$POST_HOOK_CONFIG" \
    '{"hooks": {"PreToolUse": [$pre], "PostToolUse": [$post]}}' > "$HOOKS_FILE"
fi

# Enable the codex_hooks feature flag in user-level config.toml. Without
# this flag set, Codex ignores hooks.json silently — the same silent-disable
# trap that motivates the cc.sandbox.enabled audit check.
USER_CONFIG="$HOME/.codex/config.toml"
mkdir -p "$HOME/.codex"
flag_was_added=false
if [[ -f "$USER_CONFIG" ]] && grep -qE '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true' "$USER_CONFIG"; then
  : # Already enabled
elif [[ -f "$USER_CONFIG" ]] && grep -qE '^\[features\]' "$USER_CONFIG"; then
  # [features] section exists but codex_hooks isn't there — append under it.
  python3 - "$USER_CONFIG" << 'PY'
import sys, re
path = sys.argv[1]
with open(path) as f:
    text = f.read()
# Match [features] up to the next [section] or EOF.
m = re.search(r'(\[features\][^\[]*)', text)
if m and 'codex_hooks' not in m.group(1):
    section = m.group(1)
    new_section = section.rstrip() + '\ncodex_hooks = true\n\n'
    with open(path, 'w') as f:
        f.write(text.replace(section, new_section))
PY
  flag_was_added=true
else
  # No [features] section — append a fresh block.
  printf '\n[features]\ncodex_hooks = true\n' >> "$USER_CONFIG"
  flag_was_added=true
fi

echo ""
echo "Hooks configured in $HOOKS_FILE"
echo ""
sandshell_diff_show "$HOOKS_FILE"
echo ""
echo "What this does:"
echo "  - Blocks obvious sandbox-disabling Bash commands before execution"
echo "  - Logs every Bash command the agent runs on the host"
echo "  - Classifies commands (git, github_cli, sandshell, read_only, unclassified)"
echo "  - Writes to ~/.sandshell/audit/<session>.jsonl (shared with Claude)"
if [[ "$flag_was_added" = true ]]; then
  echo "  - Enabled [features] codex_hooks = true in $USER_CONFIG"
fi
echo ""
echo "To remove: sandshell uninstall [user|project]"
