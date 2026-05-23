#!/usr/bin/env bash
# Tests for scripts/prune-permissions.sh: non-interactive removal by index,
# substring matching, scope filtering, dry-run, and preservation of unrelated
# settings keys.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/testlib.sh"

SCRIPT="$ROOT/scripts/prune-permissions.sh"

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/sandshell-test-prune.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

setup_fixtures() {
  local home="$1" cwd="$2"
  mkdir -p "$home/.claude" "$cwd/.claude"

  # User scope: one entry + unrelated keys to verify preservation.
  cat > "$home/.claude/settings.json" << 'JSON'
{
  "model": "opus-4.7",
  "permissions": {
    "allow": ["Bash(limactl list:*)"],
    "deny": ["Bash(dangerouslyDisableSandbox:true)"]
  },
  "sandbox": { "enabled": true }
}
JSON

  # Project-local scope: three entries.
  cat > "$cwd/.claude/settings.local.json" << 'JSON'
{
  "permissions": {
    "allow": [
      "Bash(wc:*)",
      "Bash(./scripts/detect.sh *)",
      "Bash(foobar plugin call)"
    ]
  }
}
JSON
}

# Case 1: --remove= by index removes only the listed entries, preserves
# unrelated keys, and leaves other entries in place.
HOME1="$TMPDIR_TEST/case1/home"
CWD1="$TMPDIR_TEST/case1/cwd"
setup_fixtures "$HOME1" "$CWD1"

(cd "$CWD1" && HOME="$HOME1" "$SCRIPT" --remove=1,3 --yes) > /dev/null

# Entry 1 = user-scope limactl, entry 3 = project-local "./scripts/detect.sh".
# Remaining project-local entries: Bash(wc:*) and Bash(foobar plugin call).
# Remaining user-scope: none → permissions.allow should be deleted (cleanup
# rule fires when the resulting list is empty).
if jq -e '.permissions.allow' "$HOME1/.claude/settings.json" > /dev/null 2>&1; then
  fail "case1: permissions.allow should be removed from user scope when empty"
fi
assert_json_value "$HOME1/.claude/settings.json" "model" "opus-4.7"
assert_json_value "$HOME1/.claude/settings.json" "sandbox.enabled" "true"
assert_json_value "$HOME1/.claude/settings.json" "permissions.deny.0" \
  "Bash(dangerouslyDisableSandbox:true)"

assert_json_value "$CWD1/.claude/settings.local.json" "permissions.allow.0" "Bash(wc:*)"
assert_json_value "$CWD1/.claude/settings.local.json" "permissions.allow.1" \
  "Bash(foobar plugin call)"
remaining=$(jq -r '.permissions.allow | length' "$CWD1/.claude/settings.local.json")
[[ "$remaining" == "2" ]] || fail "case1: expected 2 entries in project-local, got $remaining"

# Case 2: --remove-matching=foobar drops only the matching entry.
HOME2="$TMPDIR_TEST/case2/home"
CWD2="$TMPDIR_TEST/case2/cwd"
setup_fixtures "$HOME2" "$CWD2"

(cd "$CWD2" && HOME="$HOME2" "$SCRIPT" --remove-matching=foobar --yes) > /dev/null

# Project-local should have 2 entries left; no entry containing "foobar".
remaining=$(jq -r '.permissions.allow | length' "$CWD2/.claude/settings.local.json")
[[ "$remaining" == "2" ]] || fail "case2: expected 2 entries after substring prune, got $remaining"
if jq -e '.permissions.allow | map(select(contains("foobar"))) | length > 0' \
  "$CWD2/.claude/settings.local.json" > /dev/null; then
  fail "case2: foobar entry should have been removed"
fi
# User scope's only entry doesn't match; must be untouched.
assert_json_value "$HOME2/.claude/settings.json" "permissions.allow.0" "Bash(limactl list:*)"

# Case 3: --dry-run leaves all files unmodified.
HOME3="$TMPDIR_TEST/case3/home"
CWD3="$TMPDIR_TEST/case3/cwd"
setup_fixtures "$HOME3" "$CWD3"

before_user=$(jq -c . "$HOME3/.claude/settings.json")
before_proj=$(jq -c . "$CWD3/.claude/settings.local.json")
out=$(cd "$CWD3" && HOME="$HOME3" "$SCRIPT" --remove=all --dry-run)
[[ "$out" == *"Dry run"* ]] || fail "case3: expected 'Dry run' notice, got: $out"
after_user=$(jq -c . "$HOME3/.claude/settings.json")
after_proj=$(jq -c . "$CWD3/.claude/settings.local.json")
[[ "$before_user" == "$after_user" ]] || fail "case3: user file changed under --dry-run"
[[ "$before_proj" == "$after_proj" ]] || fail "case3: project file changed under --dry-run"

# Case 4: --scope=user-local limits enumeration; with no entries in that
# scope, exits 0 with a friendly message and touches nothing.
HOME4="$TMPDIR_TEST/case4/home"
CWD4="$TMPDIR_TEST/case4/cwd"
setup_fixtures "$HOME4" "$CWD4"

out=$(cd "$CWD4" && HOME="$HOME4" "$SCRIPT" --scope=user-local)
[[ "$out" == *"No permissions.allow entries"* ]] \
  || fail "case4: expected empty-scope message, got: $out"

# Case 5: 'all' keyword removes everything globally; both files end up with
# no permissions.allow key.
HOME5="$TMPDIR_TEST/case5/home"
CWD5="$TMPDIR_TEST/case5/cwd"
setup_fixtures "$HOME5" "$CWD5"
(cd "$CWD5" && HOME="$HOME5" "$SCRIPT" --remove=all --yes) > /dev/null
if jq -e '.permissions.allow' "$HOME5/.claude/settings.json" > /dev/null 2>&1; then
  fail "case5: user permissions.allow should be empty/removed"
fi
if jq -e '.permissions.allow' "$CWD5/.claude/settings.local.json" > /dev/null 2>&1; then
  fail "case5: project-local permissions.allow should be empty/removed"
fi

# Case 6: invalid index errors out non-zero, leaves files untouched.
HOME6="$TMPDIR_TEST/case6/home"
CWD6="$TMPDIR_TEST/case6/cwd"
setup_fixtures "$HOME6" "$CWD6"
before_proj=$(jq -c . "$CWD6/.claude/settings.local.json")
set +e
(cd "$CWD6" && HOME="$HOME6" "$SCRIPT" --remove=99 --yes) > /dev/null 2>&1
ec=$?
set -e
[[ "$ec" -ne 0 ]] || fail "case6: out-of-range index should exit non-zero"
after_proj=$(jq -c . "$CWD6/.claude/settings.local.json")
[[ "$before_proj" == "$after_proj" ]] || fail "case6: file modified despite error"

# Case 7: --yes without --remove= / --remove-matching= is an error (no
# entries are specified, and interactive prompting under --yes is nonsense).
HOME7="$TMPDIR_TEST/case7/home"
CWD7="$TMPDIR_TEST/case7/cwd"
setup_fixtures "$HOME7" "$CWD7"
set +e
err=$(cd "$CWD7" && HOME="$HOME7" "$SCRIPT" --yes 2>&1 > /dev/null)
ec=$?
set -e
[[ "$ec" -ne 0 ]] || fail "case7: --yes alone should exit non-zero"
[[ "$err" == *"--yes requires"* ]] || fail "case7: expected --yes guidance, got: $err"

echo "PASS: scripts/prune-permissions.sh (index, substring, dry-run, scope, all, validation)"
