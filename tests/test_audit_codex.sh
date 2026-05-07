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

# Case 4: config.toml present but no hooks.json → both hook findings fire,
# feature_flag does NOT fire (no hooks present means no silent-disable trap).
mkdir -p "$TMPDIR_TEST/case4/home/.codex"
cat > "$TMPDIR_TEST/case4/home/.codex/config.toml" <<'EOF'
sandbox_mode = "workspace-write"
EOF
out=$(run_codex "$TMPDIR_TEST/case4/home" "$TMPDIR_TEST/case4/cwd")
assert_finding "$out" "codex.hooks.pre_bash"
assert_finding "$out" "codex.hooks.post_bash"
assert_no_finding "$out" "codex.hooks.feature_flag"

# Case 5: hooks.json with sandshell hooks + [features] codex_hooks = true →
# no hook findings.
mkdir -p "$TMPDIR_TEST/case5/home/.codex"
cat > "$TMPDIR_TEST/case5/home/.codex/config.toml" <<'EOF'
sandbox_mode = "workspace-write"

[features]
codex_hooks = true
EOF
cat > "$TMPDIR_TEST/case5/home/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [{"matcher": "^Bash$", "hooks": [{"type": "command", "command": "/path/to/hook-pre-bash.sh"}]}],
    "PostToolUse": [{"matcher": "^Bash$", "hooks": [{"type": "command", "command": "/path/to/hook-post-bash.sh"}]}]
  }
}
EOF
out=$(run_codex "$TMPDIR_TEST/case5/home" "$TMPDIR_TEST/case5/cwd")
assert_no_finding "$out" "codex.hooks.pre_bash"
assert_no_finding "$out" "codex.hooks.post_bash"
assert_no_finding "$out" "codex.hooks.feature_flag"

# Case 6: silent-disable trap — sandshell hooks present in hooks.json, but
# [features] codex_hooks is missing → codex.hooks.feature_flag fires (high).
mkdir -p "$TMPDIR_TEST/case6/home/.codex"
cat > "$TMPDIR_TEST/case6/home/.codex/config.toml" <<'EOF'
sandbox_mode = "workspace-write"
EOF
cat > "$TMPDIR_TEST/case6/home/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [{"matcher": "^Bash$", "hooks": [{"type": "command", "command": "/path/to/hook-pre-bash.sh"}]}],
    "PostToolUse": [{"matcher": "^Bash$", "hooks": [{"type": "command", "command": "/path/to/hook-post-bash.sh"}]}]
  }
}
EOF
out=$(run_codex "$TMPDIR_TEST/case6/home" "$TMPDIR_TEST/case6/cwd")
assert_finding "$out" "codex.hooks.feature_flag"
echo "$out" | grep -q '"severity":"high"' \
  || fail "case6: feature_flag silent-disable should be high severity, got: $out"

# Case 7: hooks.json exists but contains only non-sandshell hooks
# (e.g., user has their own pre-tool checker). Sandshell-specific findings
# still fire because our hook scripts aren't there.
mkdir -p "$TMPDIR_TEST/case7/home/.codex"
cat > "$TMPDIR_TEST/case7/home/.codex/config.toml" <<'EOF'
sandbox_mode = "workspace-write"

[features]
codex_hooks = true
EOF
cat > "$TMPDIR_TEST/case7/home/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [{"matcher": "^Bash$", "hooks": [{"type": "command", "command": "/usr/local/bin/my-custom-checker.sh"}]}]
  }
}
EOF
out=$(run_codex "$TMPDIR_TEST/case7/home" "$TMPDIR_TEST/case7/cwd")
assert_finding "$out" "codex.hooks.pre_bash"
assert_finding "$out" "codex.hooks.post_bash"

echo "PASS: codex audit checks (sandbox_mode, approval_policy, network, trust, hooks)"
