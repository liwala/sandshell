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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/diff-apply.sh
. "$SCRIPT_DIR/lib/diff-apply.sh"

usage() {
  cat << EOF
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
    user | project)
      SCOPE="$1"
      shift
      ;;
    workspace)
      SCOPE="project"
      echo "Note: 'workspace' is the legacy name for 'project' — both still accepted." >&2
      shift
      ;;
    --show)
      SHOW_ONLY=true
      shift
      ;;
    -h | --help | help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v jq > /dev/null 2>&1; then
  echo "ERROR: jq is required. Install it (brew install jq / apt install jq)." >&2
  exit 1
fi

case "$SCOPE" in
  user)
    SETTINGS_DIR="$HOME/.gemini"
    SETTINGS_FILE="$SETTINGS_DIR/settings.json"
    ;;
  project)
    SETTINGS_DIR=".gemini"
    SETTINGS_FILE="$SETTINGS_DIR/settings.json"
    ;;
esac

# Pick the right tools.sandbox value for this OS.
#
# macOS: sandbox-exec (Seatbelt) is the universal default. Filesystem
# isolation works; network deny is broken upstream (see KNOWN_ISSUES.md).
#
# Linux: sandbox-exec doesn't exist (it's a macOS binary). Gemini's Linux
# backends are docker, podman, lxc, runsc — all require external runtimes.
# We pick docker > podman > (omit) by detecting what's installed:
#   - docker present → tools.sandbox = "docker" (with --internal network
#     when sandboxNetworkAccess=false; verified in gemini-cli source)
#   - else podman   → tools.sandbox = "podman"
#   - else          → omit tools.sandbox; the audit will flag the gap so
#                     the user knows sandboxing is unavailable until they
#                     install docker or podman.
#
# SANDSHELL_FAKE_UNAME overrides the OS detection for tests.
sandbox_value=""
sandbox_note=""
os_name="${SANDSHELL_FAKE_UNAME:-$(uname -s)}"
case "$os_name" in
  Darwin)
    sandbox_value="sandbox-exec"
    sandbox_note="Seatbelt; filesystem ✓, network broken upstream"
    ;;
  Linux)
    if command -v docker > /dev/null 2>&1; then
      sandbox_value="docker"
      sandbox_note="Docker container with --internal network when sandboxNetworkAccess=false"
    elif command -v podman > /dev/null 2>&1; then
      sandbox_value="podman"
      sandbox_note="Podman container with --internal network when sandboxNetworkAccess=false"
    else
      sandbox_value=""
      sandbox_note="no container runtime detected — Gemini sandboxing unavailable until docker or podman is installed"
    fi
    ;;
  *)
    sandbox_value=""
    sandbox_note="unrecognized OS '$os_name' — leaving tools.sandbox unset"
    ;;
esac

# Build the JSON. tools.sandbox is omitted entirely if empty (we'd rather
# leave the key off than write an invalid value the audit can't reason about).
if [[ -n "$sandbox_value" ]]; then
  GEMINI_CONFIG=$(jq -n --arg sb "$sandbox_value" '{
    "sandshell_managed": true,
    "tools": {
      "sandbox": $sb,
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
else
  GEMINI_CONFIG=$(jq -n '{
    "sandshell_managed": true,
    "tools": {
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
fi

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
sandshell_diff_snapshot "$SETTINGS_FILE"

if [[ -f "$SETTINGS_FILE" ]]; then
  if grep -q '"sandshell_managed"' "$SETTINGS_FILE" 2> /dev/null; then
    echo "Updating existing sandshell-managed config in $SETTINGS_FILE"
  fi
  existing=$(cat "$SETTINGS_FILE")
  # When sandbox_value is empty (Linux without docker/podman), don't write
  # tools.sandbox at all — and remove any prior sandshell-written value so
  # we don't leave a stale macOS-only "sandbox-exec" sitting on a Linux box.
  if [[ -n "$sandbox_value" ]]; then
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
  else
    updated=$(echo "$existing" | jq --argjson new "$GEMINI_CONFIG" '
      .sandshell_managed = true |
      .tools = (.tools // {} | del(.sandbox)) |
      .tools.sandboxNetworkAccess = $new.tools.sandboxNetworkAccess |
      .security = (.security // {}) |
      .security.folderTrust = $new.security.folderTrust |
      .security.disableYoloMode = $new.security.disableYoloMode |
      .security.disableAlwaysAllow = $new.security.disableAlwaysAllow |
      .general = (.general // {}) |
      .general.defaultApprovalMode = $new.general.defaultApprovalMode
    ')
  fi
  echo "$updated" | jq '.' > "$SETTINGS_FILE"
else
  echo "$GEMINI_CONFIG" | jq '.' > "$SETTINGS_FILE"
fi

echo ""
sandshell_diff_show "$SETTINGS_FILE"

cat << EOF

Gemini safe defaults written to $SETTINGS_FILE

OS detected: $os_name
tools.sandbox: ${sandbox_value:-<unset>} ($sandbox_note)

What this enforces:
  - Folder trust gating: YES (security.folderTrust.enabled)
  - YOLO mode: DISABLED (security.disableYoloMode=true)
  - 'Always allow' bypass: DISABLED (security.disableAlwaysAllow=true)
EOF

case "$os_name" in
  Darwin)
    cat << 'EOF'
  - Filesystem isolation: YES (Seatbelt via tools.sandbox=sandbox-exec)

What this DOES NOT enforce on macOS today:
  - Network restriction: tools.sandboxNetworkAccess is silently ignored under
    sandbox-exec. Gemini's macOS Seatbelt profiles all permit network egress.
    See KNOWN_ISSUES.md for details and workarounds.

For real network containment on macOS:
  - Switch tools.sandbox to "docker" or "podman" (uses --internal network)
  - Or run a proxy at localhost:8877 and set SEATBELT_PROFILE=permissive-proxied
EOF
    ;;
  Linux)
    if [[ -n "$sandbox_value" ]]; then
      cat << EOF
  - Filesystem + network isolation: YES via $sandbox_value container
    (--internal network when sandboxNetworkAccess=false)
EOF
    else
      cat << 'EOF'
  - Sandboxing: NOT CONFIGURED. Gemini on Linux requires docker, podman, lxc,
    or runsc — none detected on this host. Install one and re-run
    'sandshell apply gemini' to enable sandboxing.
EOF
    fi
    ;;
  *)
    cat << EOF
  - Sandboxing: NOT CONFIGURED for OS '$os_name'. Manual configuration required.
EOF
    ;;
esac

cat << EOF

VERIFY in any new Gemini session, run:
  echo test > "\$HOME/sandshell-probe.txt"
The write should fail under a working sandbox.

To remove: edit $SETTINGS_FILE or delete the file.
EOF

# Refresh the drift baseline so the next 'sandshell audit' compares against
# this post-apply state.
"$SCRIPT_DIR/audit-config.sh" --snapshot --no-drift --json > /dev/null 2>&1 || true
# shellcheck source=lib/baseline.sh
. "$SCRIPT_DIR/lib/baseline.sh"
echo "Baseline saved. $(sandshell_baseline_summary)."
