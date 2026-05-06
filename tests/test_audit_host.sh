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

# Case 3: literal cred export emits creds_in_shell_rc at medium with
# source=literal in details.
mkdir -p "$TMPDIR_TEST/case3/home"
cat > "$TMPDIR_TEST/case3/home/.zshrc" <<'EOF'
export AWS_ACCESS_KEY_ID=AKIAFAKE
EOF
out=$(run_host "$TMPDIR_TEST/case3/home" "$TMPDIR_TEST/case3/cwd")
assert_finding "$out" "host.creds_in_shell_rc"
echo "$out" | grep -q '"severity":"medium"' \
  || fail "case3: literal cred should be medium severity, got: $out"
echo "$out" | grep -q "source: literal value" \
  || fail "case3: details should mention 'source: literal value', got: $out"

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
assert_no_finding "$out" "host.creds_in_shell_rc"
assert_no_finding "$out" "host.cwd_is_git_repo"

# Case 7: known vault tools are silent (no finding emitted).
mkdir -p "$TMPDIR_TEST/case7/home" "$TMPDIR_TEST/case7/cwd"
cat > "$TMPDIR_TEST/case7/home/.zshrc" <<'EOF'
export OPENAI_API_KEY="$(op read 'op://Personal/OpenAI/key')"
export ANTHROPIC_API_KEY=$(pass show anthropic/api-key)
export GH_TOKEN=$(gh auth token)
export GITHUB_TOKEN=$(aws-vault exec dev -- aws ssm get-parameter --name gh-token --query Parameter.Value --output text)
export GOOGLE_API_KEY=$(vault read -field=key secret/google)
EOF
(cd "$TMPDIR_TEST/case7/cwd" && git init -q)
out=$(run_host "$TMPDIR_TEST/case7/home" "$TMPDIR_TEST/case7/cwd")
assert_no_finding "$out" "host.creds_in_shell_rc"

# Case 8: unknown command substitution → info-level finding.
mkdir -p "$TMPDIR_TEST/case8/home" "$TMPDIR_TEST/case8/cwd"
cat > "$TMPDIR_TEST/case8/home/.zshrc" <<'EOF'
export OPENAI_API_KEY=$(my-custom-fetcher --service=openai)
EOF
(cd "$TMPDIR_TEST/case8/cwd" && git init -q)
out=$(run_host "$TMPDIR_TEST/case8/home" "$TMPDIR_TEST/case8/cwd")
assert_finding "$out" "host.creds_in_shell_rc"
echo "$out" | grep -q '"severity":"info"' \
  || fail "case8: unknown substitution should be info severity, got: $out"
echo "$out" | grep -q "command substitution from an unrecognized tool" \
  || fail "case8: details should mention unrecognized command, got: $out"

# Case 9: $VAR forwarding → info-level finding.
mkdir -p "$TMPDIR_TEST/case9/home" "$TMPDIR_TEST/case9/cwd"
cat > "$TMPDIR_TEST/case9/home/.zshrc" <<'EOF'
export OPENAI_API_KEY=$STORED_KEY
EOF
(cd "$TMPDIR_TEST/case9/cwd" && git init -q)
out=$(run_host "$TMPDIR_TEST/case9/home" "$TMPDIR_TEST/case9/cwd")
assert_finding "$out" "host.creds_in_shell_rc"
echo "$out" | grep -q "Credential forwarded from another variable" \
  || fail "case9: should detect varref forwarding, got: $out"

# Case 10: cwd .envrc (direnv) is scanned — literal cred there is flagged.
mkdir -p "$TMPDIR_TEST/case10/home" "$TMPDIR_TEST/case10/cwd"
cat > "$TMPDIR_TEST/case10/cwd/.envrc" <<'EOF'
export OPENAI_API_KEY=sk-literal-in-envrc
EOF
(cd "$TMPDIR_TEST/case10/cwd" && git init -q)
out=$(run_host "$TMPDIR_TEST/case10/home" "$TMPDIR_TEST/case10/cwd")
assert_finding "$out" "host.creds_in_shell_rc"
echo "$out" | grep -q ".envrc" \
  || fail "case10: scope should reference .envrc, got: $out"

# Case 11: gcloud secrets versions access — silent.
mkdir -p "$TMPDIR_TEST/case11/home" "$TMPDIR_TEST/case11/cwd"
cat > "$TMPDIR_TEST/case11/home/.zshrc" <<'EOF'
export OPENAI_API_KEY=$(gcloud secrets versions access latest --secret openai-key)
EOF
(cd "$TMPDIR_TEST/case11/cwd" && git init -q)
out=$(run_host "$TMPDIR_TEST/case11/home" "$TMPDIR_TEST/case11/cwd")
assert_no_finding "$out" "host.creds_in_shell_rc"

echo "PASS: host audit checks (alias bypass, env bypass, creds-in-rc with source classification, .envrc, git repo)"
