#!/usr/bin/env bash
# sandshell: install container runtime and optional tools
set -euo pipefail

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

usage() {
  echo "Usage: install.sh <docker|lima|pipelock|all>"
  echo ""
  echo "Installs container runtimes and optional security tools."
  echo ""
  echo "  docker    Install Docker Desktop (macOS) or Docker Engine (Linux)"
  echo "  lima      Install Lima VM manager"
  echo "  pipelock  Install Pipelock prompt injection scanner (optional)"
  echo "  all       Install docker + lima + pipelock"
  exit 1
}

check() { command -v "$1" >/dev/null 2>&1; }

install_docker() {
  if check docker && docker info >/dev/null 2>&1; then
    echo "Docker is already installed and running."
    return 0
  fi

  case "$OS" in
    darwin)
      if check brew; then
        echo "Installing Docker Desktop via Homebrew..."
        brew install --cask docker
        echo ""
        echo "Docker Desktop installed. Open it from Applications to start the daemon."
        echo "Then re-run your sandshell command."
      else
        echo "Install Docker Desktop from: https://docs.docker.com/desktop/install/mac-install/"
        exit 1
      fi
      ;;
    linux)
      echo "Installing Docker Engine..."
      if check apt-get; then
        curl -fsSL https://get.docker.com | sh
        sudo usermod -aG docker "$USER"
        echo ""
        echo "Docker installed. You may need to log out and back in for group changes."
        echo "Or run: newgrp docker"
      elif check dnf; then
        sudo dnf install -y docker
        sudo systemctl enable --now docker
        sudo usermod -aG docker "$USER"
      else
        echo "Install Docker from: https://docs.docker.com/engine/install/"
        exit 1
      fi
      ;;
    *)
      echo "Unsupported OS: $OS"
      echo "Install Docker from: https://docs.docker.com/get-docker/"
      exit 1
      ;;
  esac
}

install_lima() {
  if check limactl; then
    echo "Lima is already installed."
    return 0
  fi

  case "$OS" in
    darwin)
      if check brew; then
        echo "Installing Lima via Homebrew..."
        brew install lima
      else
        echo "Install Homebrew first: https://brew.sh"
        echo "Then run: brew install lima"
        exit 1
      fi
      ;;
    linux)
      echo "Installing Lima from GitHub releases..."
      local version
      version=$(curl -sL https://api.github.com/repos/lima-vm/lima/releases/latest \
        | grep tag_name | cut -d'"' -f4)

      local lima_arch="$ARCH"
      [[ "$ARCH" = "aarch64" ]] && lima_arch="aarch64"
      [[ "$ARCH" = "x86_64" ]] && lima_arch="x86_64"

      local url="https://github.com/lima-vm/lima/releases/download/${version}/lima-${version#v}-$(uname -s)-${lima_arch}.tar.gz"
      echo "Downloading $url"
      curl -fsSL "$url" | sudo tar -xz -C /usr/local
      echo "Lima ${version} installed."
      ;;
    *)
      echo "Unsupported OS: $OS"
      echo "Install Lima from: https://lima-vm.io"
      exit 1
      ;;
  esac
}

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
  docker)   install_docker ;;
  lima)     install_lima ;;
  pipelock) install_pipelock ;;
  all)
    install_docker
    install_lima
    install_pipelock
    ;;
  *)        usage ;;
esac
