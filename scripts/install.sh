#!/usr/bin/env bash
# sandshell: install optional tools
set -euo pipefail

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

usage() {
  echo "Usage: install.sh pipelock"
  echo ""
  echo "Installs optional prompt-injection scanning support."
  exit 1
}

check() { command -v "$1" >/dev/null 2>&1; }

install_pipelock() {
  if check pipelock; then
    echo "Pipelock is already installed."
    return 0
  fi

  case "$OS" in
    darwin)
      if check brew; then
        echo "Installing Pipelock via Homebrew..."
        brew install luckyPipewrench/tap/pipelock
      else
        echo "Install Homebrew first: https://brew.sh"
        echo "Then run: brew install luckyPipewrench/tap/pipelock"
        exit 1
      fi
      ;;
    linux)
      echo "Installing Pipelock from GitHub releases..."
      local pipelock_arch="$ARCH"
      [[ "$ARCH" = "x86_64" ]] && pipelock_arch="amd64"
      [[ "$ARCH" = "aarch64" ]] && pipelock_arch="arm64"

      local url="https://github.com/luckyPipewrench/pipelock/releases/latest/download/pipelock-linux-${pipelock_arch}"
      echo "Downloading $url"
      curl -fsSL -o /tmp/pipelock "$url"
      chmod +x /tmp/pipelock
      sudo mv /tmp/pipelock /usr/local/bin/pipelock
      echo "Pipelock installed."
      ;;
    *)
      echo "Unsupported OS. Download from: https://github.com/luckyPipewrench/pipelock"
      exit 1
      ;;
  esac
}

# ─── Dispatch ────────────────────────────────────────────────────────

case "${1:-help}" in
  pipelock) install_pipelock ;;
  *)        usage ;;
esac
