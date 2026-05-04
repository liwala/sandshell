#!/usr/bin/env bash
# Tests scripts/setup-gemini.sh — merges safe defaults into a JSON config,
# is idempotent on re-apply, supports user and project scopes, and --show
# is a dry-run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/testlib.sh"

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/sandshell-test-gemini.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Case 1: fresh install (user scope) writes the expected fields.
HOME="$TMPDIR_TEST/case1" "$ROOT/scripts/setup-gemini.sh" user >/dev/null
config="$TMPDIR_TEST/case1/.gemini/settings.json"
[[ -f "$config" ]] || fail "case1: $config was not written"
assert_json_value "$config" "sandshell_managed" "true"
assert_json_value "$config" "tools.sandbox" "sandbox-exec"
assert_json_value "$config" "tools.sandboxNetworkAccess" "false"
assert_json_value "$config" "security.folderTrust.enabled" "true"
assert_json_value "$config" "security.disableYoloMode" "true"
assert_json_value "$config" "security.disableAlwaysAllow" "true"
assert_json_value "$config" "general.defaultApprovalMode" "default"

# Case 2: idempotent — re-apply preserves expected values.
HOME="$TMPDIR_TEST/case1" "$ROOT/scripts/setup-gemini.sh" user >/dev/null
assert_json_value "$config" "tools.sandbox" "sandbox-exec"
assert_json_value "$config" "security.folderTrust.enabled" "true"

# Case 3: merges into an existing non-sandshell config — preserves unrelated keys.
mkdir -p "$TMPDIR_TEST/case3/.gemini"
cat > "$TMPDIR_TEST/case3/.gemini/settings.json" <<'EOF'
{
  "myCustomKey": "preserved",
  "tools": {"sandbox": "true", "someOtherTool": "kept"}
}
EOF
HOME="$TMPDIR_TEST/case3" "$ROOT/scripts/setup-gemini.sh" user >/dev/null
assert_json_value "$TMPDIR_TEST/case3/.gemini/settings.json" "myCustomKey" "preserved"
assert_json_value "$TMPDIR_TEST/case3/.gemini/settings.json" "tools.someOtherTool" "kept"
assert_json_value "$TMPDIR_TEST/case3/.gemini/settings.json" "tools.sandbox" "sandbox-exec"

# Case 4: project scope writes to ./.gemini/settings.json.
ws_dir="$TMPDIR_TEST/case4"
mkdir -p "$ws_dir"
(cd "$ws_dir" && HOME="$TMPDIR_TEST/case4-home" "$ROOT/scripts/setup-gemini.sh" project >/dev/null)
[[ -f "$ws_dir/.gemini/settings.json" ]] \
  || fail "case4: project settings.json was not written"
assert_json_value "$ws_dir/.gemini/settings.json" "sandshell_managed" "true"

# Case 4b: legacy 'workspace' alias still accepted.
ws_dir2="$TMPDIR_TEST/case4b"
mkdir -p "$ws_dir2"
(cd "$ws_dir2" && HOME="$TMPDIR_TEST/case4b-home" "$ROOT/scripts/setup-gemini.sh" workspace 2>/dev/null >/dev/null)
[[ -f "$ws_dir2/.gemini/settings.json" ]] \
  || fail "case4b: legacy 'workspace' alias did not produce same result as 'project'"

# Case 5: --show is dry-run.
out=$(HOME="$TMPDIR_TEST/case5" "$ROOT/scripts/setup-gemini.sh" --show 2>&1)
[[ "$out" == *"Config that would be applied"* ]] \
  || fail "case5: --show output unexpected: $out"
[[ ! -f "$TMPDIR_TEST/case5/.gemini/settings.json" ]] \
  || fail "case5: --show should not write a file"

echo "PASS: setup-gemini merges safe defaults, preserves other keys, supports user/project scopes (workspace alias)"
