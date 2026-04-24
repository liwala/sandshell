#!/usr/bin/env bash
# sandshell: install instructions for a specific AI coding agent
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SANDSHELL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENTS_DIR="$SANDSHELL_DIR/agents"
CORE_TEMPLATE="$AGENTS_DIR/SANDSHELL.md"
CODEX_TEMPLATE="$AGENTS_DIR/CODEX.md"
GENERIC_TEMPLATE="$AGENTS_DIR/GENERIC.md"

usage() {
  echo "Usage: install-agent.sh <agent> [personal|project]"
  echo ""
  echo "Installs sandshell instructions for a specific AI coding agent."
  echo ""
  echo "Agents:"
  echo "  claude    Claude Code — installs SKILL.md to .claude/skills/sandshell/"
  echo "  codex     OpenAI Codex CLI — installs SKILL.md to .codex/skills/sandshell/"
  echo "  generic   Writes SANDSHELL.md for unsupported agents"
  echo "  gemini    Gemini CLI — appends to GEMINI.md"
  echo "  amp       Amp (Sourcegraph) — appends to AGENTS.md"
  echo "  all       Install for all supported agents"
  echo ""
  echo "Scope:"
  echo "  personal  Install to user-level config (default)"
  echo "  project   Install to project-level config"
  exit 0
}

# Generate agent-specific instructions by replacing placeholders.
render_template() {
  local template="$1"
  local path="$2"
  sed "s|__SANDSHELL_DIR__|${path}|g" "$template"
}

write_skill_header() {
  local target_file="$1"
  local description="$2"
  cat > "$target_file" <<HEADER
---
name: sandshell
description: >
  $description
---

HEADER
}

append_templates() {
  local target_file="$1"
  local sandshell_path="$2"
  shift 2

  for template in "$@"; do
    render_template "$template" "$sandshell_path" >> "$target_file"
    printf '\n' >> "$target_file"
  done
}

append_marked_templates() {
  local target_file="$1"
  local sandshell_path="$2"
  shift 2

  if [[ -f "$target_file" ]]; then
    echo "" >> "$target_file"
    echo "<!-- sandshell: begin -->" >> "$target_file"
  else
    echo "<!-- sandshell: begin -->" > "$target_file"
  fi

  for template in "$@"; do
    render_template "$template" "$sandshell_path" >> "$target_file"
    printf '\n' >> "$target_file"
  done

  echo "<!-- sandshell: end -->" >> "$target_file"
}

install_claude() {
  local scope="${1:-personal}"
  local target_dir

  case "$scope" in
    personal) target_dir="$HOME/.claude/skills/sandshell" ;;
    project)  target_dir=".claude/skills/sandshell" ;;
  esac

  # Claude Code uses its own SKILL.md with special features
  if [[ -d "$target_dir" ]] && [[ -f "$target_dir/SKILL.md" ]]; then
    echo "Claude Code: sandshell already installed at $target_dir"
    return 0
  fi

  # For Claude Code, just symlink or copy the whole skill directory
  if [[ "$scope" = "personal" ]]; then
    mkdir -p "$HOME/.claude/skills"
    if [[ -L "$target_dir" ]]; then
      rm "$target_dir"
    fi
    ln -sf "$SANDSHELL_DIR" "$target_dir"
    echo "Claude Code: symlinked $target_dir → $SANDSHELL_DIR"
  else
    mkdir -p "$target_dir"
    cp "$SANDSHELL_DIR/SKILL.md" "$target_dir/SKILL.md"
    # Symlink scripts so they stay up to date
    ln -sf "$SANDSHELL_DIR/scripts" "$target_dir/scripts"
    ln -sf "$SANDSHELL_DIR/profiles" "$target_dir/profiles"
    echo "Claude Code: installed to $target_dir"
  fi

  echo "  Run: $SANDSHELL_DIR/scripts/setup.sh $scope"
}

install_codex() {
  local scope="${1:-personal}"
  local target_dir

  case "$scope" in
    personal) target_dir="$HOME/.codex/skills/sandshell" ;;
    project)  target_dir=".codex/skills/sandshell" ;;
  esac

  mkdir -p "$target_dir"

  local sandshell_path="$SANDSHELL_DIR"
  [[ "$scope" = "project" ]] && sandshell_path=".codex/skills/sandshell"

  write_skill_header \
    "$target_dir/SKILL.md" \
    "Defense-in-depth for coding agents. Codex CLI adapter with native approval-mode guidance plus optional sandshell audit helpers."
  append_templates "$target_dir/SKILL.md" "$sandshell_path" \
    "$CORE_TEMPLATE" \
    "$CODEX_TEMPLATE"

  # Symlink scripts
  ln -sf "$SANDSHELL_DIR/scripts" "$target_dir/scripts" 2>/dev/null || \
    cp -r "$SANDSHELL_DIR/scripts" "$target_dir/scripts"
  ln -sf "$SANDSHELL_DIR/profiles" "$target_dir/profiles" 2>/dev/null || \
    cp -r "$SANDSHELL_DIR/profiles" "$target_dir/profiles"

  echo "Codex CLI: installed to $target_dir"
  echo "  Note: this installs Codex-native guidance only; setup.sh/setup-hooks.sh still configure Claude Code settings, not Codex"
}

install_generic() {
  local scope="${1:-project}"
  local target_file
  local sandshell_path="$SANDSHELL_DIR"

  case "$scope" in
    personal) target_file="$HOME/.sandshell/SANDSHELL.md" ;;
    project)  target_file="SANDSHELL.md" ;;
  esac

  [[ "$scope" = "project" ]] && sandshell_path="."
  mkdir -p "$(dirname "$target_file")"

  : > "$target_file"
  append_templates "$target_file" "$sandshell_path" \
    "$CORE_TEMPLATE" \
    "$GENERIC_TEMPLATE"

  echo "Generic agent instructions: wrote $target_file"
  echo "  Use this file as repo guidance for unsupported agents."
}

install_gemini() {
  local scope="${1:-personal}"
  local target_file

  case "$scope" in
    personal) target_file="$HOME/.gemini/GEMINI.md" ;;
    project)  target_file="GEMINI.md" ;;
  esac

  local sandshell_path="$SANDSHELL_DIR"

  # Check if sandshell section already exists
  if [[ -f "$target_file" ]] && grep -q "sandshell" "$target_file" 2>/dev/null; then
    echo "Gemini CLI: sandshell already in $target_file"
    return 0
  fi

  mkdir -p "$(dirname "$target_file")"
  append_marked_templates "$target_file" "$sandshell_path" "$CORE_TEMPLATE"

  echo "Gemini CLI: appended sandshell instructions to $target_file"
  echo "  Note: Gemini CLI has no hooks — audit trail relies on script-level logging"
}

install_amp() {
  local scope="${1:-project}"
  local target_file="AGENTS.md"

  if [[ "$scope" = "personal" ]]; then
    echo "Amp: personal scope not supported (Amp reads AGENTS.md from the repo)"
    echo "  Installing to project scope instead."
  fi

  local sandshell_path="$SANDSHELL_DIR"

  # Check if sandshell section already exists
  if [[ -f "$target_file" ]] && grep -q "sandshell" "$target_file" 2>/dev/null; then
    echo "Amp: sandshell already in $target_file"
    return 0
  fi

  append_marked_templates "$target_file" "$sandshell_path" "$CORE_TEMPLATE"

  echo "Amp: appended sandshell instructions to $target_file"
  echo "  Note: Amp has no hooks or skill system — instructions are advisory"
}

install_all() {
  local scope="${1:-personal}"
  echo "Installing sandshell for all supported agents..."
  echo ""
  install_claude "$scope"
  echo ""
  install_codex "$scope"
  echo ""
  install_gemini "$scope"
  echo ""
  install_amp "$scope"
  echo ""
  echo "Done. All agents configured."
}

# ─── Dispatch ────────────────────────────────────────────────────────

AGENT="${1:-help}"
SCOPE="${2:-personal}"

case "$AGENT" in
  claude)  install_claude "$SCOPE" ;;
  codex)   install_codex "$SCOPE" ;;
  generic) install_generic "$SCOPE" ;;
  gemini)  install_gemini "$SCOPE" ;;
  amp)     install_amp "$SCOPE" ;;
  all)     install_all "$SCOPE" ;;
  --help|-h|help) usage ;;
  *)
    echo "Unknown agent: $AGENT" >&2
    echo "Supported: claude, codex, generic, gemini, amp, all" >&2
    exit 1
    ;;
esac
