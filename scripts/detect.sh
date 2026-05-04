#!/usr/bin/env bash
# sandshell: report host inventory — OS, architecture, native sandbox primitive,
# dependencies, and which AI coding agents are installed.
#
# Pure inventory: this answers "what do I have?". For "is it safe?", run
# `sandshell audit` (per-finding) or `sandshell audit --summary` (per-agent
# rollup). Output is key=value lines with optional comment hints prefixed by `#`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SANDSHELL_CLI="$(cd "$SCRIPT_DIR/.." && pwd)/bin/sandshell"

# OS and architecture
echo "os=$(uname -s | tr '[:upper:]' '[:lower:]')"
echo "arch=$(uname -m)"

# Native OS sandbox primitive (Seatbelt on macOS, bubblewrap on Linux)
case "$(uname -s)" in
  Darwin)
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

# Dependencies — jq, python3 version, tomllib (for Codex audit)
if command -v jq >/dev/null 2>&1; then
  echo "dep_jq=present"
else
  echo "dep_jq=missing"
  echo "# Required: brew install jq (macOS) / apt install jq (Linux)"
fi

if command -v python3 >/dev/null 2>&1; then
  py_ver="$(python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")' 2>/dev/null || echo "unknown")"
  echo "dep_python3=$py_ver"
  if python3 -c 'import tomllib' >/dev/null 2>&1; then
    echo "dep_tomllib=available"
  else
    echo "dep_tomllib=unavailable"
    echo "# Codex audit needs Python 3.11+ for tomllib (built-in)"
  fi
else
  echo "dep_python3=missing"
  echo "dep_tomllib=unavailable"
  echo "# Required: install python3 (macOS: ships by default; Linux: apt install python3)"
fi

# Agent presence — does the user have each known agent?
agent_present() {
  local name="$1" cmd="$2"
  shift 2
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "agent_${name}=installed"
    return
  fi
  local hint
  for hint in "$@"; do
    if [[ -e "$hint" ]]; then
      echo "agent_${name}=config_only"
      return
    fi
  done
  echo "agent_${name}=absent"
}

agent_present claude  claude  "$HOME/.claude"  "$HOME/.claude.json"  ".claude"
agent_present codex   codex   "$HOME/.codex"
agent_present gemini  gemini  "$HOME/.gemini"  ".gemini"
agent_present amp     amp     "$HOME/.config/amp"  ".amp"

# Pointer to audit if any agent is present.
if command -v claude >/dev/null 2>&1 || [[ -d "$HOME/.claude" ]] \
   || command -v codex >/dev/null 2>&1 || [[ -d "$HOME/.codex" ]] \
   || command -v gemini >/dev/null 2>&1 || [[ -d "$HOME/.gemini" ]]; then
  echo "# For safety evaluation: $SANDSHELL_CLI audit"
fi
