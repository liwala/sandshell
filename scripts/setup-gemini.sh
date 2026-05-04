#!/usr/bin/env bash
# sandshell: write safe defaults to ~/.gemini/settings.json (user scope) or
# .gemini/settings.json (project scope; Gemini's docs call this "workspace").
#
# IMPORTANT macOS caveat: under tools.sandbox = "sandbox-exec" (the universal
# default on macOS), the sandboxNetworkAccess setting is silently ignored —
# Gemini ships only "open" or "proxied" Seatbelt profiles, none that actually
# block network. Filesystem isolation does work via Seatbelt. For real network
# enforcement, switch tools.sandbox to "docker" or "podman" (creates --internal
# network with no egress), or run a proxy at localhost:8877 with
# GEMINI_SANDBOX_PROXY_COMMAND.
#
# Source: packages/cli/src/utils/sandbox.ts (Seatbelt branch never reads
# config.networkAccess); Issues #20381, #20046.
set -euo pipefail

usage() {
  cat <<EOF
Usage: setup-gemini.sh [user|project] [--show]

  user      Install to ~/.gemini/settings.json (default)
  project   Install to .gemini/settings.json in cwd (Gemini's docs call this "workspace")
  --show    Print the config that would be applied (dry-run)
  -h, --help

Legacy scope names accepted: 'workspace' (alias for 'project').

Writes:
  - tools.sandbox = "sandbox-exec" (universal on macOS; filesystem-only)
  - tools.sandboxNetworkAccess = false (forward-correct; honored under
    docker/podman; silently ignored under sandbox-exec on macOS today)
  - security.folderTrust.enabled = true
  - security.disableYoloMode = true
  - security.disableAlwaysAllow = true
  - general.defaultApprovalMode = "default"

For real network containment on macOS, see KNOWN_ISSUES.md.
EOF
}

SCOPE="user"
SHOW_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    user|project)   SCOPE="$1"; shift ;;
    workspace)
      SCOPE="project"
      echo "Note: 'workspace' is the legacy name for 'project' — both still accepted." >&2
      shift
      ;;
    --show)         SHOW_ONLY=true; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required. Install it (brew install jq / apt install jq)." >&2
  exit 1
fi

case "$SCOPE" in
  user)    SETTINGS_DIR="$HOME/.gemini"; SETTINGS_FILE="$SETTINGS_DIR/settings.json" ;;
  project) SETTINGS_DIR=".gemini";       SETTINGS_FILE="$SETTINGS_DIR/settings.json" ;;
esac

GEMINI_CONFIG=$(jq -n '{
  "sandshell_managed": true,
  "tools": {
    "sandbox": "sandbox-exec",
    "sandboxNetworkAccess": false
  },
  "security": {
    "folderTrust": {"enabled": true},
    "disableYoloMode": true,
    "disableAlwaysAllow": true
  },
  "general": {
    "defaultApprovalMode": "default"
  }
}')

echo "sandshell: Gemini CLI safe defaults"
echo "  Scope: $SCOPE"
echo "  File:  $SETTINGS_FILE"
echo ""

if [[ "$SHOW_ONLY" = true ]]; then
  echo "Config that would be applied:"
  echo ""
  echo "$GEMINI_CONFIG" | jq '.'
  exit 0
fi

mkdir -p "$SETTINGS_DIR"

if [[ -f "$SETTINGS_FILE" ]]; then
  if grep -q '"sandshell_managed"' "$SETTINGS_FILE" 2>/dev/null; then
    echo "Updating existing sandshell-managed config in $SETTINGS_FILE"
  fi
  existing=$(cat "$SETTINGS_FILE")
  updated=$(echo "$existing" | jq --argjson new "$GEMINI_CONFIG" '
    .sandshell_managed = true |
    .tools = (.tools // {}) |
    .tools.sandbox = $new.tools.sandbox |
    .tools.sandboxNetworkAccess = $new.tools.sandboxNetworkAccess |
    .security = (.security // {}) |
    .security.folderTrust = $new.security.folderTrust |
    .security.disableYoloMode = $new.security.disableYoloMode |
    .security.disableAlwaysAllow = $new.security.disableAlwaysAllow |
    .general = (.general // {}) |
    .general.defaultApprovalMode = $new.general.defaultApprovalMode
  ')
  echo "$updated" | jq '.' > "$SETTINGS_FILE"
else
  echo "$GEMINI_CONFIG" | jq '.' > "$SETTINGS_FILE"
fi

cat <<EOF

Gemini safe defaults written to $SETTINGS_FILE

What this enforces:
  - Filesystem isolation: YES (Seatbelt via tools.sandbox=sandbox-exec)
  - Folder trust gating: YES (security.folderTrust.enabled)
  - YOLO mode: DISABLED (security.disableYoloMode=true)
  - 'Always allow' bypass: DISABLED (security.disableAlwaysAllow=true)

What this DOES NOT enforce on macOS today:
  - Network restriction: tools.sandboxNetworkAccess is silently ignored under
    sandbox-exec. Gemini's macOS Seatbelt profiles all permit network egress.
    See KNOWN_ISSUES.md for details and workarounds.

For real network containment on macOS:
  - Switch tools.sandbox to "docker" or "podman" (uses --internal network)
  - Or run a proxy at localhost:8877 and set SEATBELT_PROFILE=permissive-proxied

VERIFY filesystem enforcement — in any new Gemini session, run:
  echo test > "\$HOME/sandshell-probe.txt"
The write should fail with "Operation not permitted".

To remove: edit $SETTINGS_FILE or delete the file.
EOF
