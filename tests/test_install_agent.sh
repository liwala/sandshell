#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/testlib.sh"

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/sandshell-test-install.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

mkdir -p "$TMPDIR_TEST/project" "$TMPDIR_TEST/home"
export HOME="$TMPDIR_TEST/home"

(
  cd "$TMPDIR_TEST/project"
  "$ROOT/scripts/install-agent.sh" codex project >/dev/null
  "$ROOT/scripts/install-agent.sh" claude project >/dev/null
  "$ROOT/scripts/install-agent.sh" generic project >/dev/null
)

CODEX_SKILL="$TMPDIR_TEST/project/.codex/skills/sandshell/SKILL.md"
CLAUDE_SKILL="$TMPDIR_TEST/project/.claude/skills/sandshell/SKILL.md"
GENERIC_GUIDE="$TMPDIR_TEST/project/SANDSHELL.md"
assert_file_contains "$CODEX_SKILL" "name: sandshell"
assert_file_contains "$CODEX_SKILL" "Prefer \`Suggest\` or \`Auto Edit\` for normal work"
assert_file_contains "$CODEX_SKILL" "codex --full-auto"
assert_file_not_contains "$CODEX_SKILL" "setup.sh personal"
assert_file_contains "$CLAUDE_SKILL" "name: sandshell"
assert_file_contains "$GENERIC_GUIDE" "Prefer the agent's strongest native sandbox"
assert_file_contains "$GENERIC_GUIDE" "Use these instructions through the agent's own project-instruction"
assert_symlink_target "$TMPDIR_TEST/project/.codex/skills/sandshell/scripts" "$ROOT/scripts"
assert_symlink_target "$TMPDIR_TEST/project/.codex/skills/sandshell/profiles" "$ROOT/profiles"
assert_symlink_target "$TMPDIR_TEST/project/.claude/skills/sandshell/scripts" "$ROOT/scripts"
assert_symlink_target "$TMPDIR_TEST/project/.claude/skills/sandshell/profiles" "$ROOT/profiles"

echo "PASS: install-agent project mode"
