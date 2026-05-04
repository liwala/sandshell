#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/testlib.sh"

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/sandshell-test-host.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

ADAPTER="$ROOT/agents/host/audit.sh"

run_host() {
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

# Case 1: shell_alias_bypass fires on a bypass alias.
mkdir -p "$TMPDIR_TEST/case1/home"
cat > "$TMPDIR_TEST/case1/home/.zshrc" <<'EOF'
alias claude='claude --dangerously-skip-permissions'
EOF
out=$(run_host "$TMPDIR_TEST/case1/home" "$TMPDIR_TEST/case1/cwd")
assert_finding "$out" "host.shell_alias_bypass"

# Case 2: env_bypass_var fires on persistent bypass export.
mkdir -p "$TMPDIR_TEST/case2/home"
cat > "$TMPDIR_TEST/case2/home/.zshrc" <<'EOF'
export CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS=1
EOF
out=$(run_host "$TMPDIR_TEST/case2/home" "$TMPDIR_TEST/case2/cwd")
assert_finding "$out" "host.env_bypass_var"

# Case 3: long_lived_creds fires on bare AWS_ACCESS_KEY_ID.
mkdir -p "$TMPDIR_TEST/case3/home"
cat > "$TMPDIR_TEST/case3/home/.zshrc" <<'EOF'
export AWS_ACCESS_KEY_ID=AKIAFAKE
EOF
out=$(run_host "$TMPDIR_TEST/case3/home" "$TMPDIR_TEST/case3/cwd")
assert_finding "$out" "host.long_lived_creds"

# Case 4: AWS_SESSION_TOKEN suppresses the AWS finding (treats as STS/SSO).
mkdir -p "$TMPDIR_TEST/case4/home"
cat > "$TMPDIR_TEST/case4/home/.zshrc" <<'EOF'
export AWS_ACCESS_KEY_ID=AKIAFAKE
export AWS_SESSION_TOKEN=fake-session
EOF
out=$(run_host "$TMPDIR_TEST/case4/home" "$TMPDIR_TEST/case4/cwd")
echo "$out" | grep -q "AWS_ACCESS_KEY_ID" \
  && fail "AWS_SESSION_TOKEN should suppress AWS_ACCESS_KEY_ID warning, got: $out" || true

# Case 5: cwd_is_git_repo fires when cwd is not a git repo.
mkdir -p "$TMPDIR_TEST/case5/home" "$TMPDIR_TEST/case5/cwd"
out=$(run_host "$TMPDIR_TEST/case5/home" "$TMPDIR_TEST/case5/cwd")
assert_finding "$out" "host.cwd_is_git_repo"

# Case 6: clean environment → no host findings.
mkdir -p "$TMPDIR_TEST/case6/home" "$TMPDIR_TEST/case6/cwd"
(cd "$TMPDIR_TEST/case6/cwd" && git init -q)
out=$(run_host "$TMPDIR_TEST/case6/home" "$TMPDIR_TEST/case6/cwd")
assert_no_finding "$out" "host.shell_alias_bypass"
assert_no_finding "$out" "host.env_bypass_var"
assert_no_finding "$out" "host.long_lived_creds"
assert_no_finding "$out" "host.cwd_is_git_repo"

echo "PASS: host audit checks (alias bypass, env bypass, long-lived creds, git repo)"
