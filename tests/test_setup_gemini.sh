#!/usr/bin/env bash
# Tests scripts/setup-gemini.sh — merges safe defaults into a JSON config,
# is idempotent on re-apply, supports user and project scopes, and --show
# is a dry-run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/testlib.sh"

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/sandshell-test-gemini.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Pin OS to Darwin for the macOS-path cases so they pass regardless of the
# host running the test (CI is Linux). The Linux branch has its own cases
# below.
export SANDSHELL_FAKE_UNAME=Darwin

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

# ---------- Linux backend selection ----------
unset SANDSHELL_FAKE_UNAME

# A PATH with no container runtime. /usr/bin:/bin is NOT a safe stand-in for
# "nothing installed" — GitHub's ubuntu runners ship docker at /usr/bin/docker,
# so the no-runtime cases below would (correctly) pick it up and fail. Mirror
# the real PATH into a scratch dir, symlinking everything except the runtimes
# setup-gemini.sh probes for, so docker/podman/lxc/runsc presence is controlled
# entirely by the test while every other tool the script needs stays reachable.
NO_RUNTIME_BIN="$TMPDIR_TEST/no-runtime-bin"
mkdir -p "$NO_RUNTIME_BIN"
IFS=':' read -ra _path_dirs <<< "$PATH"
for _dir in "${_path_dirs[@]}"; do
  [[ -d "$_dir" ]] || continue
  for _bin in "$_dir"/*; do
    [[ -e "$_bin" ]] || continue
    _name="$(basename "$_bin")"
    case "$_name" in
      docker|podman|lxc|lxc-*|runsc) continue ;;
    esac
    [[ -e "$NO_RUNTIME_BIN/$_name" ]] || ln -s "$_bin" "$NO_RUNTIME_BIN/$_name" 2>/dev/null || true
  done
done

# Case 6: Linux + docker available → tools.sandbox = "docker".
mkdir -p "$TMPDIR_TEST/case6/fakebin"
cat > "$TMPDIR_TEST/case6/fakebin/docker" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMPDIR_TEST/case6/fakebin/docker"
SANDSHELL_FAKE_UNAME=Linux PATH="$TMPDIR_TEST/case6/fakebin:$PATH" \
  HOME="$TMPDIR_TEST/case6" "$ROOT/scripts/setup-gemini.sh" user >/dev/null
assert_json_value "$TMPDIR_TEST/case6/.gemini/settings.json" "tools.sandbox" "docker"
assert_json_value "$TMPDIR_TEST/case6/.gemini/settings.json" "tools.sandboxNetworkAccess" "false"

# Case 7: Linux + only podman → tools.sandbox = "podman".
mkdir -p "$TMPDIR_TEST/case7/fakebin"
cat > "$TMPDIR_TEST/case7/fakebin/podman" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMPDIR_TEST/case7/fakebin/podman"
# Restrict PATH to the no-runtime bin (docker stripped) plus the fake podman,
# so podman is the only runtime visible regardless of what the host has.
SANDSHELL_FAKE_UNAME=Linux PATH="$TMPDIR_TEST/case7/fakebin:$NO_RUNTIME_BIN" \
  HOME="$TMPDIR_TEST/case7" "$ROOT/scripts/setup-gemini.sh" user >/dev/null
actual=$(jq -r '.tools.sandbox // "<unset>"' "$TMPDIR_TEST/case7/.gemini/settings.json")
[[ "$actual" == "podman" ]] \
  || fail "case7: expected tools.sandbox=podman, got: $actual"

# Case 8: Linux + neither docker nor podman → tools.sandbox is OMITTED.
SANDSHELL_FAKE_UNAME=Linux PATH="$NO_RUNTIME_BIN" \
  HOME="$TMPDIR_TEST/case8" "$ROOT/scripts/setup-gemini.sh" user >/dev/null
config8="$TMPDIR_TEST/case8/.gemini/settings.json"
[[ -f "$config8" ]] || fail "case8: settings.json was not written"
[[ "$(jq -r '.tools.sandbox // "<unset>"' "$config8")" == "<unset>" ]] \
  || fail "case8: tools.sandbox should be omitted on Linux without container runtime, got: $(jq '.tools' "$config8")"
# Other safety keys still get written.
assert_json_value "$config8" "tools.sandboxNetworkAccess" "false"
assert_json_value "$config8" "security.disableYoloMode" "true"

# Case 9: Stale sandbox-exec on Linux gets removed on re-apply (the merge
# path strips it when the OS can't deliver it).
mkdir -p "$TMPDIR_TEST/case9/.gemini"
cat > "$TMPDIR_TEST/case9/.gemini/settings.json" <<'EOF'
{"sandshell_managed": true, "tools": {"sandbox": "sandbox-exec", "sandboxNetworkAccess": false}}
EOF
SANDSHELL_FAKE_UNAME=Linux PATH="$NO_RUNTIME_BIN" \
  HOME="$TMPDIR_TEST/case9" "$ROOT/scripts/setup-gemini.sh" user >/dev/null
[[ "$(jq -r '.tools.sandbox // "<unset>"' "$TMPDIR_TEST/case9/.gemini/settings.json")" == "<unset>" ]] \
  || fail "case9: stale sandbox-exec should be stripped on Linux re-apply"

echo "PASS: setup-gemini merges safe defaults, preserves other keys, supports user/project scopes, OS-aware sandbox backend"
