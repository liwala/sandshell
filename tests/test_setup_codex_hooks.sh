#!/usr/bin/env bash
# Tests scripts/setup-codex-hooks.sh — writes ~/.codex/hooks.json with
# PreToolUse/PostToolUse entries pointing at sandshell's hook scripts,
# enables [features] codex_hooks = true in ~/.codex/config.toml, idempotent
# on re-run, supports project scope.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/testlib.sh"

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/sandshell-test-codex-hooks.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Case 1: fresh install at user scope writes hooks.json + config.toml flag.
HOME="$TMPDIR_TEST/case1" "$ROOT/scripts/setup-codex-hooks.sh" user >/dev/null
hooks="$TMPDIR_TEST/case1/.codex/hooks.json"
config="$TMPDIR_TEST/case1/.codex/config.toml"
[[ -f "$hooks" ]]  || fail "case1: hooks.json was not written"
[[ -f "$config" ]] || fail "case1: config.toml was not written"
assert_json_value "$hooks" "hooks.PreToolUse.0.matcher" "^Bash$"
assert_json_value "$hooks" "hooks.PreToolUse.0.hooks.0.command" "$ROOT/scripts/hook-pre-bash.sh"
assert_json_value "$hooks" "hooks.PostToolUse.0.matcher" "^Bash$"
assert_json_value "$hooks" "hooks.PostToolUse.0.hooks.0.command" "$ROOT/scripts/hook-post-bash.sh"
grep -qE '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true' "$config" \
  || fail "case1: codex_hooks = true not set in config.toml"

# Case 2: re-running is idempotent — file content stays the same.
before_hash=$(python3 -c "import hashlib,sys;print(hashlib.sha256(open('$hooks','rb').read()).hexdigest())")
HOME="$TMPDIR_TEST/case1" "$ROOT/scripts/setup-codex-hooks.sh" user >/dev/null
after_hash=$(python3 -c "import hashlib,sys;print(hashlib.sha256(open('$hooks','rb').read()).hexdigest())")
[[ "$before_hash" == "$after_hash" ]] \
  || fail "case2: re-running setup-codex-hooks should be idempotent"

# Case 3: existing [features] section with another flag — codex_hooks gets
# inserted into the same section, not duplicated. Other keys preserved.
mkdir -p "$TMPDIR_TEST/case3/.codex"
cat > "$TMPDIR_TEST/case3/.codex/config.toml" <<'EOF'
sandbox_mode = "workspace-write"

[features]
some_other_flag = true

[tui]
theme = "dark"
EOF
HOME="$TMPDIR_TEST/case3" "$ROOT/scripts/setup-codex-hooks.sh" user >/dev/null
config3="$TMPDIR_TEST/case3/.codex/config.toml"
grep -qE '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true' "$config3" \
  || fail "case3: codex_hooks = true should be added"
grep -qE '^[[:space:]]*some_other_flag[[:space:]]*=[[:space:]]*true' "$config3" \
  || fail "case3: existing some_other_flag was clobbered"
grep -qE '^\[tui\]' "$config3" \
  || fail "case3: existing [tui] section was clobbered"
# Should not have created a SECOND [features] block
[[ $(grep -c '^\[features\]' "$config3") -eq 1 ]] \
  || fail "case3: [features] block was duplicated"

# Case 4: project scope writes to .codex/hooks.json in cwd, doesn't touch
# config.toml at project scope (feature flag stays at user level only).
mkdir -p "$TMPDIR_TEST/case4/cwd"
HOME="$TMPDIR_TEST/case4/home" \
  bash -c "cd '$TMPDIR_TEST/case4/cwd' && '$ROOT/scripts/setup-codex-hooks.sh' project" >/dev/null
project_hooks="$TMPDIR_TEST/case4/cwd/.codex/hooks.json"
[[ -f "$project_hooks" ]] || fail "case4: project-scope hooks.json was not written"
assert_json_value "$project_hooks" "hooks.PreToolUse.0.matcher" "^Bash$"
# User-level config.toml should still get the feature flag (it's the gate
# that enables Codex to read hooks at all).
[[ -f "$TMPDIR_TEST/case4/home/.codex/config.toml" ]] \
  || fail "case4: user config.toml should still be created for the feature flag"

# Case 5: 'workspace' is accepted as a legacy alias for 'project'.
mkdir -p "$TMPDIR_TEST/case5/cwd"
out=$(HOME="$TMPDIR_TEST/case5/home" \
  bash -c "cd '$TMPDIR_TEST/case5/cwd' && '$ROOT/scripts/setup-codex-hooks.sh' workspace" 2>&1)
[[ "$out" == *"legacy name"* ]] \
  || fail "case5: 'workspace' should print legacy-alias notice, got: $out"
[[ -f "$TMPDIR_TEST/case5/cwd/.codex/hooks.json" ]] \
  || fail "case5: 'workspace' should resolve to project scope (.codex/hooks.json)"

echo "PASS: setup-codex-hooks writes hooks.json, enables codex_hooks feature flag, idempotent, supports project scope"
