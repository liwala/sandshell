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

echo "PASS: gemini audit checks (sandbox, folder trust, yolo, approval, trusted folders)"
