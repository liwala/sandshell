#!/usr/bin/env bash
# Tests scripts/setup-codex.sh — writes a TOML config with the sandshell-managed
# safety defaults; refuses to overwrite a non-managed file without --force;
# is idempotent on re-apply.
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

# Case 3: refuses to overwrite a non-sandshell file without --force.
mkdir -p "$TMPDIR_TEST/case3/.codex"
echo '# user content not sandshell' > "$TMPDIR_TEST/case3/.codex/config.toml"
set +e
HOME="$TMPDIR_TEST/case3" "$ROOT/scripts/setup-codex.sh" >/dev/null 2>&1
ec=$?
set -e
[[ "$ec" -ne 0 ]] || fail "case3: expected non-zero exit on conflict, got $ec"
grep -q "user content not sandshell" "$TMPDIR_TEST/case3/.codex/config.toml" \
  || fail "case3: original content was overwritten"

# Case 4: --force overwrites the existing non-managed file.
HOME="$TMPDIR_TEST/case3" "$ROOT/scripts/setup-codex.sh" --force >/dev/null
grep -q "Managed by sandshell" "$TMPDIR_TEST/case3/.codex/config.toml" \
  || fail "case4: --force did not overwrite"

# Case 5: --show is dry-run (writes nothing).
out=$(HOME="$TMPDIR_TEST/case5" "$ROOT/scripts/setup-codex.sh" --show 2>&1)
[[ "$out" == *"Config that would be written"* ]] \
  || fail "case5: --show output unexpected: $out"
[[ ! -f "$TMPDIR_TEST/case5/.codex/config.toml" ]] \
  || fail "case5: --show should not write a file"

echo "PASS: setup-codex writes safe defaults, refuses unmanaged overwrite, --show is dry-run"
