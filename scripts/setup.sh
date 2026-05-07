#!/usr/bin/env bash
# sandshell: one-command setup for all protection layers
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  echo "Usage: setup.sh [user|project] [--profile=default|node|python] [--strict]"
  echo ""
  echo "Configures the supported sandshell release path in one command:"
  echo ""
  echo "  1. Claude Code native sandbox (OS-enforced filesystem + network restrictions)"
  echo "  2. Claude Code Bash guard + audit hooks"
  echo ""
  echo "Options:"
  echo "  user             Install to ~/.claude/settings.json (default; was 'personal' in v0.1)"
  echo "  project          Install to .claude/settings.json"
  echo "  --profile=NAME   Network profile: default, node, python"
  echo "  --strict         Also deny reads to ~/.ssh, ~/.aws, ~/.kube, etc."
  echo "  --skip-sandbox   Skip native sandbox setup"
  echo "  --skip-hooks     Skip audit hooks setup"
  echo ""
  echo "Legacy scope names accepted: 'personal' (alias for 'user')."
  exit 0
}

SCOPE="user"
PROFILE="default"
EXTRA_ARGS=""
SKIP_SANDBOX=false
SKIP_HOOKS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    user|project) SCOPE="$1"; shift ;;
    personal)
      SCOPE="user"
      echo "Note: 'personal' is the legacy name for 'user' — both still accepted." >&2
      shift
      ;;
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

# Summary
echo "==============="
echo "Setup complete!"
echo ""
echo "Protection layers active:"
[[ "$SKIP_SANDBOX" = false ]] && echo "  [x] Native OS sandbox (kernel-enforced filesystem; macOS network is broken upstream — see KNOWN_ISSUES.md)"
[[ "$SKIP_HOOKS" = false ]]   && echo "  [x] Audit hooks (Bash command audit-trail to ~/.sandshell/audit/)"
echo ""
echo "Verify filesystem enforcement in any new Claude Code session:"
echo "  echo test > \"\$HOME/sandshell-probe.txt\"   # should fail: Operation not permitted"
echo ""
echo "Network on macOS is currently affected by upstream bug #37970 — curl to"
echo "non-allowlisted hosts will succeed despite the allowlist. For tasks that"
echo "actually need network containment, run: sandshell apply codex"
echo "(Codex's macOS sandbox is real Seatbelt MAC and enforces network at"
echo "kernel level, verified empirically.)"
echo ""
echo "Run 'sandshell audit' for the full per-finding view, or 'sandshell audit"
echo "--summary' for a one-line-per-agent rollup."

# Refresh the drift baseline so the next 'sandshell audit' compares against
# this post-apply state. Silent on success; warnings (if any) go to stderr.
"$SCRIPT_DIR/audit-config.sh" --snapshot --no-drift --json >/dev/null 2>&1 || true
# shellcheck source=lib/baseline.sh
. "$SCRIPT_DIR/lib/baseline.sh"
echo "Baseline saved. $(sandshell_baseline_summary)."
