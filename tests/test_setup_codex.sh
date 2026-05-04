#!/usr/bin/env bash
# Tests scripts/setup-codex.sh — writes a TOML config with the sandshell-managed
# safety defaults; merges by default into existing non-managed configs (preserving
# user keys); is idempotent on re-apply; --force unconditionally overwrites.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/testlib.sh"

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/sandshell-test-codex.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Case 1: fresh install writes a sandshell-managed file.
HOME="$TMPDIR_TEST/case1" "$ROOT/scripts/setup-codex.sh" >/dev/null
config="$TMPDIR_TEST/case1/.codex/config.toml"
[[ -f "$config" ]] || fail "case1: $config was not written"
grep -q "Managed by sandshell" "$config" \
  || fail "case1: missing sandshell marker comment"
grep -q '^sandbox_mode = "workspace-write"' "$config" \
  || fail "case1: sandbox_mode not set correctly"
grep -q '^approval_policy = "on-request"' "$config" \
  || fail "case1: approval_policy not set correctly"
grep -q '^network_access = false' "$config" \
  || fail "case1: network_access not set to false"

# Case 2: re-apply on an existing sandshell-managed file is idempotent.
HOME="$TMPDIR_TEST/case1" "$ROOT/scripts/setup-codex.sh" >/dev/null
grep -q "Managed by sandshell" "$config" || fail "case2: marker lost on re-apply"

# Case 3: merges by default into a non-sandshell file — preserves user keys
# while applying sandshell's safety keys.
mkdir -p "$TMPDIR_TEST/case3/.codex"
cat > "$TMPDIR_TEST/case3/.codex/config.toml" <<'EOF'
model = "gpt-5"
some_user_key = "preserved"

[profiles.work]
sandbox_mode = "workspace-write"
EOF
HOME="$TMPDIR_TEST/case3" "$ROOT/scripts/setup-codex.sh" >/dev/null
merged="$TMPDIR_TEST/case3/.codex/config.toml"
grep -q '^model = "gpt-5"' "$merged" \
  || fail "case3 (merge): user's 'model' key was not preserved"
grep -q '^some_user_key = "preserved"' "$merged" \
  || fail "case3 (merge): user's custom key was not preserved"
grep -q '^\[profiles\.work\]' "$merged" \
  || fail "case3 (merge): user's [profiles.work] section was not preserved"
grep -q '^sandbox_mode = "workspace-write"' "$merged" \
  || fail "case3 (merge): sandshell sandbox_mode was not applied"
grep -q '^approval_policy = "on-request"' "$merged" \
  || fail "case3 (merge): sandshell approval_policy was not applied"
grep -q '^network_access = false' "$merged" \
  || fail "case3 (merge): sandshell network_access was not applied"
grep -q "Managed by sandshell" "$merged" \
  || fail "case3 (merge): sandshell marker comment missing after merge"

# Case 3b: re-apply on a sandshell-managed file that ALSO has user/Codex
# keys (the situation a user actually ends up in: marker present, but Codex
# itself wrote [tui.*] settings or the user added [projects.*] over time).
# Re-apply MUST preserve those — the marker means "we wrote here" not "we
# own everything in this file". Bug fixed in v0.2.0 polish; regression test.
mkdir -p "$TMPDIR_TEST/case3b/.codex"
cat > "$TMPDIR_TEST/case3b/.codex/config.toml" <<'EOF'
# Managed by sandshell — old marker text from earlier version

sandbox_mode = "workspace-write"
approval_policy = "on-request"

[sandbox_workspace_write]
network_access = false
writable_roots = ["/tmp/already-trusted"]

[projects."/some/trusted/project"]
trust_level = "trusted"

[tui.model_availability_nux]
"gpt-5.5" = 2
EOF
HOME="$TMPDIR_TEST/case3b" "$ROOT/scripts/setup-codex.sh" >/dev/null
managed_with_extras="$TMPDIR_TEST/case3b/.codex/config.toml"
grep -q '\[projects\."/some/trusted/project"\]' "$managed_with_extras" \
  || fail "case3b: re-apply lost [projects.\"...\"] (the bug we just fixed)"
grep -q 'trust_level = "trusted"' "$managed_with_extras" \
  || fail "case3b: re-apply lost trust_level = \"trusted\""
grep -q '\[tui\.model_availability_nux\]' "$managed_with_extras" \
  || fail "case3b: re-apply lost [tui.*] section (Codex-internal setting)"
grep -q '"/tmp/already-trusted"' "$managed_with_extras" \
  || fail "case3b: re-apply lost user's writable_roots entries"
# Re-applying a second time should be idempotent (no further changes).
sha_before=$(shasum "$managed_with_extras" | awk '{print $1}')
HOME="$TMPDIR_TEST/case3b" "$ROOT/scripts/setup-codex.sh" >/dev/null
sha_after=$(shasum "$managed_with_extras" | awk '{print $1}')
[[ "$sha_before" = "$sha_after" ]] \
  || fail "case3b: re-apply was not idempotent (file changed on second run)"

# Case 4: --force overwrites the existing non-managed file (drops user keys).
mkdir -p "$TMPDIR_TEST/case4/.codex"
cat > "$TMPDIR_TEST/case4/.codex/config.toml" <<'EOF'
some_user_key = "should-be-gone"
EOF
HOME="$TMPDIR_TEST/case4" "$ROOT/scripts/setup-codex.sh" --force >/dev/null
forced="$TMPDIR_TEST/case4/.codex/config.toml"
grep -q "Managed by sandshell" "$forced" \
  || fail "case4 (--force): did not overwrite to sandshell-managed"
if grep -q "some_user_key" "$forced"; then
  fail "case4 (--force): user key should have been dropped, but is still present"
fi

# Case 5: --show is dry-run (writes nothing).
out=$(HOME="$TMPDIR_TEST/case5" "$ROOT/scripts/setup-codex.sh" --show 2>&1)
[[ "$out" == *"Config that would be written"* ]] \
  || fail "case5: --show output unexpected: $out"
[[ ! -f "$TMPDIR_TEST/case5/.codex/config.toml" ]] \
  || fail "case5: --show should not write a file"

echo "PASS: setup-codex writes safe defaults, merges into existing user configs, --force overwrites, --show is dry-run"
