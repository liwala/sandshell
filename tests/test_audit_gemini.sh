#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/testlib.sh"

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/sandshell-test-gemini.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

ADAPTER="$ROOT/agents/gemini/audit.sh"

run_gemini() {
  local home="$1" cwd="$2"
  mkdir -p "$home" "$cwd"
  (cd "$cwd" && HOME="$home" "$ADAPTER" 2>/dev/null)
}

assert_finding() {
  local out="$1" id="$2"
  echo "$out" | grep -q "\"id\":\"$id\"" \
    || fail "Expected finding '$id', got: $out"
}

assert_no_finding() {
  local out="$1" id="$2"
  if echo "$out" | grep -q "\"id\":\"$id\""; then
    fail "Did not expect finding '$id', got: $out"
  fi
}

# Case 1: dangerous defaults — every check should fire.
mkdir -p "$TMPDIR_TEST/case1/home/.gemini"
cat > "$TMPDIR_TEST/case1/home/.gemini/settings.json" <<'EOF'
{
  "tools": {
    "sandboxNetworkAccess": true,
    "sandboxAllowedPaths": ["/"]
  },
  "general": {"defaultApprovalMode": "auto_edit"},
  "security": {
    "folderTrust": {"enabled": false},
    "disableYoloMode": false,
    "disableAlwaysAllow": false
  }
}
EOF
cat > "$TMPDIR_TEST/case1/home/.gemini/trustedFolders.json" <<'EOF'
{"/": "trusted"}
EOF
out=$(run_gemini "$TMPDIR_TEST/case1/home" "$TMPDIR_TEST/case1/cwd")
assert_finding "$out" "gemini.sandbox_enabled"
assert_finding "$out" "gemini.sandbox_network_off"
assert_finding "$out" "gemini.sandbox_paths_bounded"
assert_finding "$out" "gemini.folder_trust_enabled"
assert_finding "$out" "gemini.disable_yolo"
assert_finding "$out" "gemini.disable_always_allow"
assert_finding "$out" "gemini.approval_mode"
assert_finding "$out" "gemini.trusted_folders_bounded"

# Case 2: safe defaults — sandbox/yolo/folder-trust/always-allow checks pass.
mkdir -p "$TMPDIR_TEST/case2/home/.gemini"
cat > "$TMPDIR_TEST/case2/home/.gemini/settings.json" <<'EOF'
{
  "tools": {"sandbox": "docker", "sandboxNetworkAccess": false},
  "general": {"defaultApprovalMode": "default"},
  "security": {
    "folderTrust": {"enabled": true},
    "disableYoloMode": true,
    "disableAlwaysAllow": true
  }
}
EOF
out=$(run_gemini "$TMPDIR_TEST/case2/home" "$TMPDIR_TEST/case2/cwd")
assert_no_finding "$out" "gemini.sandbox_enabled"
assert_no_finding "$out" "gemini.folder_trust_enabled"
assert_no_finding "$out" "gemini.disable_yolo"
assert_no_finding "$out" "gemini.disable_always_allow"
assert_no_finding "$out" "gemini.approval_mode"

# Helper for OS-mocked runs.
run_gemini_os() {
  local home="$1" cwd="$2" os="$3" path_override="${4:-}"
  mkdir -p "$home" "$cwd"
  if [[ -n "$path_override" ]]; then
    (cd "$cwd" && SANDSHELL_FAKE_UNAME="$os" PATH="$path_override" HOME="$home" "$ADAPTER" 2>/dev/null)
  else
    (cd "$cwd" && SANDSHELL_FAKE_UNAME="$os" HOME="$home" "$ADAPTER" 2>/dev/null)
  fi
}

# Case 3: Linux + tools.sandbox = "sandbox-exec" → linux_invalid (high).
mkdir -p "$TMPDIR_TEST/case3/home/.gemini"
cat > "$TMPDIR_TEST/case3/home/.gemini/settings.json" <<'EOF'
{"tools": {"sandbox": "sandbox-exec", "sandboxNetworkAccess": false}}
EOF
out=$(run_gemini_os "$TMPDIR_TEST/case3/home" "$TMPDIR_TEST/case3/cwd" "Linux")
assert_finding "$out" "gemini.sandbox.linux_invalid"
echo "$out" | grep -q '"severity":"high"' \
  || fail "case3: linux_invalid should be high severity, got: $out"

# Case 4: Linux + tools.sandbox unset + no docker/podman/lxc available →
# linux_runtime_missing (high).
mkdir -p "$TMPDIR_TEST/case4/home/.gemini"
cat > "$TMPDIR_TEST/case4/home/.gemini/settings.json" <<'EOF'
{"tools": {"sandboxNetworkAccess": false}}
EOF
out=$(run_gemini_os "$TMPDIR_TEST/case4/home" "$TMPDIR_TEST/case4/cwd" "Linux" "/usr/bin:/bin")
assert_finding "$out" "gemini.sandbox.linux_runtime_missing"

# Case 5: Linux + tools.sandbox = "docker" but docker not installed →
# linux_runtime_missing (high).
mkdir -p "$TMPDIR_TEST/case5/home/.gemini"
cat > "$TMPDIR_TEST/case5/home/.gemini/settings.json" <<'EOF'
{"tools": {"sandbox": "docker", "sandboxNetworkAccess": false}}
EOF
out=$(run_gemini_os "$TMPDIR_TEST/case5/home" "$TMPDIR_TEST/case5/cwd" "Linux" "/usr/bin:/bin")
assert_finding "$out" "gemini.sandbox.linux_runtime_missing"

# Case 6: Linux + tools.sandbox = "docker" with docker present → no linux_*
# findings.
mkdir -p "$TMPDIR_TEST/case6/home/.gemini" "$TMPDIR_TEST/case6/fakebin"
cat > "$TMPDIR_TEST/case6/fakebin/docker" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TMPDIR_TEST/case6/fakebin/docker"
cat > "$TMPDIR_TEST/case6/home/.gemini/settings.json" <<'EOF'
{"tools": {"sandbox": "docker", "sandboxNetworkAccess": false}}
EOF
out=$(run_gemini_os "$TMPDIR_TEST/case6/home" "$TMPDIR_TEST/case6/cwd" "Linux" "$TMPDIR_TEST/case6/fakebin:/usr/bin:/bin")
assert_no_finding "$out" "gemini.sandbox.linux_invalid"
assert_no_finding "$out" "gemini.sandbox.linux_runtime_missing"

# Case 7: macOS + tools.sandbox = "sandbox-exec" → no linux_* findings
# (sandbox-exec is correct on macOS).
mkdir -p "$TMPDIR_TEST/case7/home/.gemini"
cat > "$TMPDIR_TEST/case7/home/.gemini/settings.json" <<'EOF'
{"tools": {"sandbox": "sandbox-exec", "sandboxNetworkAccess": false}}
EOF
out=$(run_gemini_os "$TMPDIR_TEST/case7/home" "$TMPDIR_TEST/case7/cwd" "Darwin")
assert_no_finding "$out" "gemini.sandbox.linux_invalid"
assert_no_finding "$out" "gemini.sandbox.linux_runtime_missing"

# --- Antigravity CLI (agy) transition cases ---
# PATH is pinned to system dirs (plus a fakebin) so 'gemini'/'agy' presence is
# controlled by the test, not by whatever is installed on the host. jq resolves
# from /usr/bin on both CI and macOS 15+, same as cases 4-6.
run_gemini_path() {
  local home="$1" cwd="$2" path="$3"
  mkdir -p "$home" "$cwd"
  (cd "$cwd" && PATH="$path" HOME="$home" "$ADAPTER" 2>/dev/null)
}

make_fake_bin() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local name
  for name in "$@"; do
    printf '#!/bin/sh\nexit 0\n' > "$dir/$name"
    chmod +x "$dir/$name"
  done
}

# Case 8: agy installed, gemini binary absent, Gemini config still present →
# agy_transition fires high and the legacy checks still run against the config.
mkdir -p "$TMPDIR_TEST/case8/home/.gemini"
make_fake_bin "$TMPDIR_TEST/case8/fakebin" agy
cat > "$TMPDIR_TEST/case8/home/.gemini/settings.json" <<'EOF'
{"security": {"disableYoloMode": false}}
EOF
out=$(run_gemini_path "$TMPDIR_TEST/case8/home" "$TMPDIR_TEST/case8/cwd" \
  "$TMPDIR_TEST/case8/fakebin:/usr/bin:/bin")
assert_finding "$out" "gemini.agy_transition"
echo "$out" | grep '"id":"gemini.agy_transition"' | grep -q '"severity":"high"' \
  || fail "case8: agy_transition should be high when gemini binary is absent, got: $out"
assert_finding "$out" "gemini.sandbox_enabled"

# Case 9: agy and gemini both installed → agy_transition fires at info.
mkdir -p "$TMPDIR_TEST/case9/home/.gemini"
make_fake_bin "$TMPDIR_TEST/case9/fakebin" agy gemini
cat > "$TMPDIR_TEST/case9/home/.gemini/settings.json" <<'EOF'
{"tools": {"sandbox": "docker"}}
EOF
out=$(run_gemini_path "$TMPDIR_TEST/case9/home" "$TMPDIR_TEST/case9/cwd" \
  "$TMPDIR_TEST/case9/fakebin:/usr/bin:/bin")
assert_finding "$out" "gemini.agy_transition"
echo "$out" | grep '"id":"gemini.agy_transition"' | grep -q '"severity":"info"' \
  || fail "case9: agy_transition should be info when gemini is also installed, got: $out"

# Case 10: agy-only host — ~/.gemini exists only because agy nests its config
# there; no Gemini CLI config at all → only the transition finding, no
# misleading legacy criticals.
mkdir -p "$TMPDIR_TEST/case10/home/.gemini/antigravity-cli"
out=$(run_gemini_path "$TMPDIR_TEST/case10/home" "$TMPDIR_TEST/case10/cwd" \
  "/usr/bin:/bin")
assert_finding "$out" "gemini.agy_transition"
assert_no_finding "$out" "gemini.sandbox_enabled"
assert_no_finding "$out" "gemini.folder_trust_enabled"

# Case 11: no agy anywhere → no transition finding.
mkdir -p "$TMPDIR_TEST/case11/home/.gemini"
cat > "$TMPDIR_TEST/case11/home/.gemini/settings.json" <<'EOF'
{"tools": {"sandbox": "docker"}}
EOF
out=$(run_gemini_path "$TMPDIR_TEST/case11/home" "$TMPDIR_TEST/case11/cwd" \
  "/usr/bin:/bin")
assert_no_finding "$out" "gemini.agy_transition"

echo "PASS: gemini audit checks (sandbox, folder trust, yolo, approval, trusted folders, linux backend, agy transition)"
