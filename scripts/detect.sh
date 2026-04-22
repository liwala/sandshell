#!/usr/bin/env bash
# sandshell: detect available container runtimes and optional tools
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

detect_binary() {
  local name="$1"
  local path version
  path=$(command -v "$name" 2>/dev/null) || return 1
  version=$("$path" version --format '{{.Client.Version}}' 2>/dev/null \
    || "$path" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+[.0-9]*' \
    || echo "unknown")
  echo "${name}_available=true"
  echo "${name}_path=${path}"
  echo "${name}_version=${version}"
}

# OS and architecture
echo "os=$(uname -s | tr '[:upper:]' '[:lower:]')"
echo "arch=$(uname -m)"

# Container runtimes — first available becomes the default
runtime="none"

if detect_binary docker 2>/dev/null; then
  # Verify daemon is actually running
  if docker info >/dev/null 2>&1; then
    [ "$runtime" = "none" ] && runtime="docker"
  else
    echo "docker_daemon=false"
  fi
fi

if detect_binary podman 2>/dev/null; then
  [ "$runtime" = "none" ] && runtime="podman"
fi

if detect_binary limactl 2>/dev/null; then
  [ "$runtime" = "none" ] && runtime="lima"
fi

echo "runtime=${runtime}"

if [ "$runtime" = "none" ]; then
  echo "# WARNING: No container runtime found."
  echo "# Run: ${SCRIPT_DIR}/install.sh docker   (or: lima)"
fi

# Native OS sandbox (Seatbelt on macOS, bubblewrap on Linux)
case "$(uname -s)" in
  Darwin)
    # macOS always has Seatbelt (sandbox-exec)
    if command -v sandbox-exec >/dev/null 2>&1; then
      echo "native_sandbox=seatbelt"
    else
      echo "native_sandbox=none"
    fi
    ;;
  Linux)
    if command -v bwrap >/dev/null 2>&1; then
      echo "native_sandbox=bubblewrap"
    else
      echo "native_sandbox=none"
      echo "# Optional: apt install bubblewrap (for OS-level sandboxing)"
    fi
    ;;
  *)
    echo "native_sandbox=none"
    ;;
esac

# Check if Claude Code sandbox is configured AND actually enabled.
# The `sandbox` block in settings.json is inert unless `sandbox.enabled == true`
# (CC defaults it to false). We report `true` only when enforcement will fire
# on the next fresh session; a present-but-disabled config is reported as
# `false` with a distinct warning so users don't mistake it for protection.
sandbox_is_enabled() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  python3 - "$file" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    sys.exit(0 if data.get("sandbox", {}).get("enabled") is True else 1)
except Exception:
    sys.exit(1)
PY
}

sandbox_managed_marker_present() {
  local file="$1"
  [[ -f "$file" ]] && grep -q '"sandshell_managed"' "$file" 2>/dev/null
}

if sandbox_is_enabled "$HOME/.claude/settings.json" \
   || sandbox_is_enabled ".claude/settings.json"; then
  echo "cc_sandbox_configured=true"
else
  echo "cc_sandbox_configured=false"
  if sandbox_managed_marker_present "$HOME/.claude/settings.json" \
     || sandbox_managed_marker_present ".claude/settings.json"; then
    echo "# WARNING: sandbox block present but sandbox.enabled is not true — re-run setup-sandbox.sh"
  else
    echo "# Recommended: ${SCRIPT_DIR}/setup-sandbox.sh personal --profile=default"
  fi
fi

# Check if audit hooks are configured
if [[ -f "$HOME/.claude/settings.json" ]] && grep -q "hook-post-bash.sh" "$HOME/.claude/settings.json" 2>/dev/null; then
  echo "audit_hooks_configured=true"
elif [[ -f ".claude/settings.json" ]] && grep -q "hook-post-bash.sh" ".claude/settings.json" 2>/dev/null; then
  echo "audit_hooks_configured=true"
else
  echo "audit_hooks_configured=false"
  echo "# Recommended: ${SCRIPT_DIR}/setup-hooks.sh personal"
fi

# Optional: Pipelock (prompt injection scanning)
if command -v pipelock >/dev/null 2>&1; then
  echo "pipelock_available=true"
  echo "pipelock_version=$(pipelock version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+[.0-9]*' || echo 'unknown')"
else
  echo "pipelock_available=false"
  echo "# Optional: Install Pipelock for prompt injection scanning"
  echo "# brew install luckyPipewrench/tap/pipelock"
fi
