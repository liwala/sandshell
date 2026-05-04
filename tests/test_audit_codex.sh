#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/testlib.sh"

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/sandshell-test-codex.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

ADAPTER="$ROOT/agents/codex/audit.sh"

# Skip if Python lacks tomllib (Codex audit can't run without it).
if ! python3 -c 'import tomllib' >/dev/null 2>&1; then
  echo "SKIP: codex audit checks (Python tomllib not available)"
  exit 0
fi

run_codex() {
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
mkdir -p "$TMPDIR_TEST/case1/home/.codex"
cat > "$TMPDIR_TEST/case1/home/.codex/config.toml" <<'EOF'
sandbox_mode = "danger-full-access"
approval_policy = "never"

[sandbox_workspace_write]
network_access = true
writable_roots = ["/"]

[projects."/"]
trust_level = "trusted"
EOF
out=$(run_codex "$TMPDIR_TEST/case1/home" "$TMPDIR_TEST/case1/cwd")
assert_finding "$out" "codex.sandbox_mode"
assert_finding "$out" "codex.approval_policy"
assert_finding "$out" "codex.network_access"
assert_finding "$out" "codex.writable_roots_bounded"
assert_finding "$out" "codex.no_trusted_broad_dirs"

# Case 2: safe defaults — none of the checks should fire.
mkdir -p "$TMPDIR_TEST/case2/home/.codex"
cat > "$TMPDIR_TEST/case2/home/.codex/config.toml" <<'EOF'
sandbox_mode = "workspace-write"
approval_policy = "on-request"

[sandbox_workspace_write]
network_access = false
writable_roots = ["/Users/me/code/myproj"]
EOF
out=$(run_codex "$TMPDIR_TEST/case2/home" "$TMPDIR_TEST/case2/cwd")
assert_no_finding "$out" "codex.sandbox_mode"
assert_no_finding "$out" "codex.approval_policy"
assert_no_finding "$out" "codex.network_access"
assert_no_finding "$out" "codex.writable_roots_bounded"
assert_no_finding "$out" "codex.no_trusted_broad_dirs"

# Case 3: codex installed but no config.toml → info finding.
mkdir -p "$TMPDIR_TEST/case3/home/.codex"
out=$(run_codex "$TMPDIR_TEST/case3/home" "$TMPDIR_TEST/case3/cwd")
assert_finding "$out" "codex.no_config"

echo "PASS: codex audit checks (sandbox_mode, approval_policy, network, trust)"
