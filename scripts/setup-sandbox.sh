#!/usr/bin/env bash
# sandshell: configure Claude Code's native OS sandbox (Seatbelt/bubblewrap)
# This provides kernel-level enforcement that the agent cannot bypass.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILES_DIR="$(cd "$SCRIPT_DIR/../profiles" && pwd)"

usage() {
  echo "Usage: setup-sandbox.sh [user|project] [--profile=default|node|python]"
  echo ""
  echo "Configures Claude Code's native OS sandbox (Seatbelt on macOS, bubblewrap on Linux)."
  echo "This provides kernel-level filesystem and network restrictions that the agent"
  echo "CANNOT bypass — even if prompt-injected."
  echo ""
  echo "  user      Install to ~/.claude/settings.json (default; was 'personal' in v0.1)"
  echo "  project   Install to .claude/settings.json"
  echo ""
  echo "  Legacy scope names accepted: 'personal' (alias for 'user')."
  echo ""
  echo "Options:"
  echo "  --profile=NAME  Network profile: default, node, python"
  echo "  --strict        Also deny reads to sensitive directories"
  echo "  --show          Print the config that would be applied (dry run)"
  exit 0
}

# Defaults
SCOPE="user"
PROFILE="default"
STRICT=false
SHOW_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    user|project) SCOPE="$1"; shift ;;
    personal)
      SCOPE="user"
      echo "Note: 'personal' is the legacy name for 'user' — both still accepted." >&2
      shift
      ;;
    --profile=*)      PROFILE="${1#*=}"; shift ;;
    --strict)         STRICT=true; shift ;;
    --show)           SHOW_ONLY=true; shift ;;
    --help|-h|help)   usage ;;
    *)                echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Check for jq
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required. Install it:" >&2
  echo "  macOS:  brew install jq" >&2
  echo "  Linux:  apt-get install jq" >&2
  exit 1
fi

# Determine settings file location
case "$SCOPE" in
  user)    SETTINGS_DIR="$HOME/.claude"; SETTINGS_FILE="$SETTINGS_DIR/settings.json" ;;
  project) SETTINGS_DIR=".claude"; SETTINGS_FILE="$SETTINGS_DIR/settings.json" ;;
esac

# Load allowed domains from profile
domains=()
profile_file="$PROFILES_DIR/${PROFILE}.conf"
if [[ ! -f "$profile_file" ]]; then
  echo "ERROR: Unknown profile '$PROFILE'. Available:" >&2
  ls "$PROFILES_DIR"/*.conf 2>/dev/null | xargs -I{} basename {} .conf >&2
  exit 1
fi

while IFS= read -r line; do
  line="${line%%#*}"
  line="${line// /}"
  [[ -n "$line" ]] && domains+=("$line")
done < "$profile_file"

# Build the domains JSON array
domains_json="[]"
if [[ ${#domains[@]} -gt 0 ]]; then
  domains_json=$(printf '%s\n' "${domains[@]}" | jq -R '.' | jq -s '.')
fi

# Sensitive directories to deny reads from
DENY_READ='[]'
if [[ "$STRICT" = true ]]; then
  DENY_READ=$(jq -n '[
    "~/.ssh",
    "~/.aws",
    "~/.kube",
    "~/.config/gcloud",
    "~/.docker/config.json",
    "~/.gnupg",
    "~/.netrc",
    "~/.npmrc",
    "~/.pypirc"
  ]')
fi

# Build sandbox config using Claude Code's documented schema:
#   sandbox.filesystem.allowWrite  — additional writable paths (cwd is implicit)
#   sandbox.filesystem.denyRead    — paths the agent must not read
#   sandbox.network.allowedDomains — outbound network allowlist
# Reference: https://code.claude.com/docs/en/sandboxing
#
# Note: v0.1 used the legacy field names (filesystem.write.allowOnly,
# filesystem.read.denyOnly, network.allowedHosts), which Claude Code does not
# enforce as expected (notably allowedHosts was silently ignored). The audit's
# `cc.sandbox.legacy_schema` check flags settings still using the old names.
SANDBOX_CONFIG=$(jq -n \
  --argjson domains "$domains_json" \
  --argjson deny_read "$DENY_READ" \
  '{
    "permissions": {
      "deny": [
        "Bash(dangerouslyDisableSandbox:true)"
      ]
    },
    "sandbox": {
      "enabled": true,
      "filesystem": {
        "allowWrite": ["$TMPDIR", "/tmp"],
        "denyRead": $deny_read
      },
      "network": {
        "allowedDomains": $domains
      }
    }
  }')

echo "sandshell: Claude Code native sandbox configuration"
echo "  Scope:   $SCOPE"
echo "  Profile: $PROFILE (${#domains[@]} allowed domains)"
echo "  Strict:  $STRICT"
echo ""

if [[ "$SHOW_ONLY" = true ]]; then
  echo "Config that would be applied to $SETTINGS_FILE:"
  echo ""
  echo "$SANDBOX_CONFIG" | jq '.'
  exit 0
fi

mkdir -p "$SETTINGS_DIR"

if [[ -f "$SETTINGS_FILE" ]]; then
  # Check if sandbox is already configured by sandshell
  if grep -q '"sandshell_managed"' "$SETTINGS_FILE" 2>/dev/null; then
    echo "Updating existing sandshell sandbox config in $SETTINGS_FILE"
  fi

  # Merge: sandbox config into existing settings
  existing=$(cat "$SETTINGS_FILE")

  # Deep merge sandbox settings
  updated=$(echo "$existing" | jq --argjson new "$SANDBOX_CONFIG" '
    # Merge permissions.deny arrays (deduplicate)
    .permissions.deny = ((.permissions.deny // []) + ($new.permissions.deny // []) | unique) |

    # Set sandbox config
    .sandbox = $new.sandbox |

    # Mark as sandshell-managed
    .sandshell_managed = true
  ')

  echo "$updated" | jq '.' > "$SETTINGS_FILE"
else
  # Create new settings file
  echo "$SANDBOX_CONFIG" | jq '. + {sandshell_managed: true}' > "$SETTINGS_FILE"
fi

echo "Native sandbox configured in $SETTINGS_FILE"
echo ""
echo "What this enforces:"
echo "  - Filesystem writes restricted to current working directory"
echo "    (additionally allowWrite: \$TMPDIR, /tmp)"
echo "  - --dangerouslyDisableSandbox is denied via permissions.deny"
if [[ "$STRICT" = true ]]; then
  echo "  - Reads denied to: ~/.ssh, ~/.aws, ~/.kube, ~/.gnupg, etc."
fi
echo ""
echo "Network allowlist (${#domains[@]} domains via $PROFILE profile) — IMPORTANT:"
echo "  Sandshell writes the documented allowedDomains schema (forward-correct"
echo "  + works on Linux). On macOS today, Claude Code has open bug #37970"
echo "  where allowedDomains is silently not enforced for Bash subprocesses."
echo "  See KNOWN_ISSUES.md. For tasks that genuinely need network containment,"
echo "  use sandshell apply codex (kernel-enforced via Seatbelt MAC) or Docker sbx."
echo ""
echo "Filesystem enforcement — verify in any new Claude Code session:"
echo "    echo test > \"\$HOME/sandshell-probe.txt\""
echo "  Should fail with 'Operation not permitted' (this part actually works)."
echo ""
echo "Network enforcement is currently a known-broken upstream:"
echo "    curl -sS --max-time 5 https://example.com"
echo "  Will likely succeed with HTTP 200 despite the allowlist (bug #37970)."
echo ""
echo "To remove: ${SCRIPT_DIR}/uninstall.sh user|project"
