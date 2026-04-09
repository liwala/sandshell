#!/usr/bin/env bash
# sandshell: configure Claude Code's native OS sandbox (Seatbelt/bubblewrap)
# This provides kernel-level enforcement that the agent cannot bypass.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILES_DIR="$(cd "$SCRIPT_DIR/../profiles" && pwd)"

usage() {
  echo "Usage: setup-sandbox.sh [personal|project] [--profile=default|node|python|minimal]"
  echo ""
  echo "Configures Claude Code's native OS sandbox (Seatbelt on macOS, bubblewrap on Linux)."
  echo "This provides kernel-level filesystem and network restrictions that the agent"
  echo "CANNOT bypass — even if prompt-injected."
  echo ""
  echo "  personal  Install to ~/.claude/settings.json (default)"
  echo "  project   Install to .claude/settings.json"
  echo ""
  echo "Options:"
  echo "  --profile=NAME  Network profile: default, node, python, minimal"
  echo "  --strict        Also deny reads to sensitive directories"
  echo "  --show          Print the config that would be applied (dry run)"
  exit 0
}

# Defaults
SCOPE="personal"
PROFILE="default"
STRICT=false
SHOW_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    personal|project) SCOPE="$1"; shift ;;
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
  personal) SETTINGS_DIR="$HOME/.claude"; SETTINGS_FILE="$SETTINGS_DIR/settings.json" ;;
  project)  SETTINGS_DIR=".claude"; SETTINGS_FILE="$SETTINGS_DIR/settings.json" ;;
esac

# Load allowed domains from profile
domains=()
profile_file="$PROFILES_DIR/${PROFILE}.conf"
if [[ -f "$profile_file" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line// /}"
    [[ -n "$line" ]] && domains+=("$line")
  done < "$profile_file"
fi

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

# Build sandbox config
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
      "filesystem": {
        "write": {
          "allowOnly": [".", "$TMPDIR"],
          "denyWithinAllow": []
        },
        "read": {
          "denyOnly": $deny_read,
          "allowWithinDeny": []
        }
      },
      "network": {
        "allowedHosts": $domains
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
echo "What this enforces (OS-level, agent CANNOT bypass):"
echo "  - Filesystem writes restricted to project directory + \$TMPDIR"
echo "  - Network limited to ${#domains[@]} allowed domains ($PROFILE profile)"
echo "  - --dangerouslyDisableSandbox is denied"
if [[ "$STRICT" = true ]]; then
  echo "  - Reads blocked to: ~/.ssh, ~/.aws, ~/.kube, ~/.gnupg, etc."
fi
echo ""
echo "  macOS: enforced via Seatbelt (kernel-level)"
echo "  Linux: enforced via bubblewrap (namespace-level)"
echo ""
echo "To remove: edit $SETTINGS_FILE and delete the sandbox/permissions entries."
