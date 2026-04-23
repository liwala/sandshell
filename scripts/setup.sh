#!/usr/bin/env bash
# sandshell: one-command setup for all protection layers
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  echo "Usage: setup.sh [personal|project] [--profile=default|node|python|minimal] [--strict]"
  echo ""
  echo "Configures the supported sandshell release path in one command:"
  echo ""
  echo "  1. Claude Code native sandbox (OS-enforced filesystem + network restrictions)"
  echo "  2. Claude Code Bash guard + audit hooks"
  echo "  3. Checks for Pipelock (optional prompt injection scanning)"
  echo ""
  echo "Options:"
  echo "  personal         Install to ~/.claude/settings.json (default)"
  echo "  project          Install to .claude/settings.json"
  echo "  --profile=NAME   Network profile: default, node, python, minimal"
  echo "  --strict         Also deny reads to ~/.ssh, ~/.aws, ~/.kube, etc."
  echo "  --skip-sandbox   Skip native sandbox setup"
  echo "  --skip-hooks     Skip audit hooks setup"
  exit 0
}

SCOPE="personal"
PROFILE="default"
EXTRA_ARGS=""
SKIP_SANDBOX=false
SKIP_HOOKS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    personal|project) SCOPE="$1"; shift ;;
    --profile=*)      PROFILE="${1#*=}"; EXTRA_ARGS="$EXTRA_ARGS $1"; shift ;;
    --strict)         EXTRA_ARGS="$EXTRA_ARGS --strict"; shift ;;
    --skip-sandbox)   SKIP_SANDBOX=true; shift ;;
    --skip-hooks)     SKIP_HOOKS=true; shift ;;
    --help|-h|help)   usage ;;
    *)                echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

echo "sandshell setup"
echo "==============="
echo ""

# Step 1: Native sandbox
if [[ "$SKIP_SANDBOX" = false ]]; then
  echo "--- Layer 1: Native OS sandbox ---"
  "$SCRIPT_DIR/setup-sandbox.sh" "$SCOPE" --profile="$PROFILE" $EXTRA_ARGS
  echo ""
else
  echo "--- Layer 1: Native OS sandbox (skipped) ---"
  echo ""
fi

# Step 2: Audit hooks
if [[ "$SKIP_HOOKS" = false ]]; then
  echo "--- Layer 2: Audit hooks ---"
  "$SCRIPT_DIR/setup-hooks.sh" "$SCOPE"
  echo ""
else
  echo "--- Layer 2: Audit hooks (skipped) ---"
  echo ""
fi

# Step 3: Check Pipelock
echo "--- Layer 3: Prompt injection scanning ---"
if command -v pipelock >/dev/null 2>&1; then
  echo "Pipelock detected. Web content scanning available."
else
  echo "Pipelock not installed (optional)."
  echo "  $SCRIPT_DIR/install.sh pipelock"
fi
echo ""

# Summary
echo "==============="
echo "Setup complete!"
echo ""
echo "Protection layers active:"
[[ "$SKIP_SANDBOX" = false ]] && echo "  [x] Native OS sandbox (kernel-enforced)"
[[ "$SKIP_HOOKS" = false ]]   && echo "  [x] Audit hooks (all Bash commands logged)"
command -v pipelock >/dev/null 2>&1 && echo "  [x] Pipelock (prompt injection scanning)"
command -v pipelock >/dev/null 2>&1 || echo "  [ ] Pipelock (optional, not installed)"
echo ""
echo "Verify the sandbox is enforcing. In a Claude Code session run:"
echo "  echo test > \"\$HOME/sandshell-probe.txt\"   # should be Operation not permitted"
echo "  curl -sS --max-time 5 https://example.com  # should time out"
echo "If either succeeds, enforcement is off — check sandbox.enabled and /config scopes."
echo ""
echo "Codex can use the installed skill, but this setup script only configures Claude Code."
