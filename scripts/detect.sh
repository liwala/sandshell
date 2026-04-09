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

# Optional: Pipelock (prompt injection scanning)
if command -v pipelock >/dev/null 2>&1; then
  echo "pipelock_available=true"
  echo "pipelock_version=$(pipelock version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+[.0-9]*' || echo 'unknown')"
else
  echo "pipelock_available=false"
  echo "# Optional: Install Pipelock for prompt injection scanning"
  echo "# brew install luckyPipewrench/tap/pipelock"
fi
