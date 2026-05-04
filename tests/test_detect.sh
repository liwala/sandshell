#!/usr/bin/env bash
# Tests detect.sh — pure inventory output. Safety-evaluation logic (sandbox
# enabled, silent-disable, etc.) lives in the Claude adapter and is covered
# by test_audit_claude.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/testlib.sh"

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/sandshell-test-detect.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

run_detect() {
  local home="$1" cwd="$2"
  mkdir -p "$home" "$cwd"
  (cd "$cwd" && HOME="$home" "$ROOT/scripts/detect.sh" 2>&1)
}

# detect must always emit the inventory fields.
mkdir -p "$TMPDIR_TEST/inv/home" "$TMPDIR_TEST/inv/cwd"
out=$(run_detect "$TMPDIR_TEST/inv/home" "$TMPDIR_TEST/inv/cwd")

for field in os arch native_sandbox dep_jq dep_python3 dep_tomllib \
             agent_claude agent_codex agent_gemini agent_amp; do
  echo "$out" | grep -qE "^${field}=" \
    || fail "expected '${field}=' in detect output, got: $out"
done

# os should be a recognized value, not 'unknown'.
echo "$out" | grep -qE "^os=(darwin|linux)$" \
  || fail "expected os=darwin or os=linux, got: $out"

# detect must NOT emit safety-summary fields (those moved to audit --summary).
for forbidden in cc_sandbox_configured codex_sandbox_configured \
                 gemini_sandbox_configured audit_trail_hooks_configured \
                 claude_pre_bash_hook_configured bash_guard_configured; do
  if echo "$out" | grep -qE "^${forbidden}="; then
    fail "detect should not emit safety field '${forbidden}=' (moved to audit --summary): $out"
  fi
done

# Each agent_* field must be one of: installed, config_only, absent.
# (We can't assert specifically 'absent' even with a fake HOME, because
# `command -v` checks PATH, which the test doesn't override.)
for agent in claude codex gemini amp; do
  echo "$out" | grep -qE "^agent_${agent}=(installed|config_only|absent)$" \
    || fail "expected agent_${agent} to be installed/config_only/absent, got: $out"
done

# When ~/.claude exists, agent_claude is at least config_only.
mkdir -p "$TMPDIR_TEST/with_claude/home/.claude"
out=$(run_detect "$TMPDIR_TEST/with_claude/home" "$TMPDIR_TEST/with_claude/cwd")
echo "$out" | grep -qE "^agent_claude=(config_only|installed)$" \
  || fail "expected agent_claude=config_only or installed when ~/.claude exists, got: $out"

echo "PASS: detect.sh emits inventory fields and does not leak safety state"
