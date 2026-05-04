#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/testlib.sh"

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/sandshell-test-claude.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

ADAPTER="$ROOT/agents/claude/audit.sh"

run_claude() {
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

# Case 1: sandbox.enabled critical when no scope has sandbox enabled.
mkdir -p "$TMPDIR_TEST/case1/home/.claude"
echo '{}' > "$TMPDIR_TEST/case1/home/.claude/settings.json"
out=$(run_claude "$TMPDIR_TEST/case1/home" "$TMPDIR_TEST/case1/cwd")
assert_finding "$out" "cc.sandbox.enabled"

# Case 2: silent_disable fires when sandbox block present but enabled !== true.
mkdir -p "$TMPDIR_TEST/case2/home/.claude"
echo '{"sandbox": {"enabled": false}}' > "$TMPDIR_TEST/case2/home/.claude/settings.json"
out=$(run_claude "$TMPDIR_TEST/case2/home" "$TMPDIR_TEST/case2/cwd")
assert_finding "$out" "cc.sandbox.silent_disable"

# Case 3: write_scope high when allowWrite contains broad path.
mkdir -p "$TMPDIR_TEST/case3/home/.claude"
cat > "$TMPDIR_TEST/case3/home/.claude/settings.json" <<'EOF'
{"sandbox": {"enabled": true, "filesystem": {"allowWrite": ["/"]}}}
EOF
out=$(run_claude "$TMPDIR_TEST/case3/home" "$TMPDIR_TEST/case3/cwd")
assert_finding "$out" "cc.sandbox.write_scope"

# Case 4: network_allowlist medium when allowlist contains "*".
mkdir -p "$TMPDIR_TEST/case4/home/.claude"
cat > "$TMPDIR_TEST/case4/home/.claude/settings.json" <<'EOF'
{"sandbox": {"enabled": true, "network": {"allowedDomains": ["*"]}}}
EOF
out=$(run_claude "$TMPDIR_TEST/case4/home" "$TMPDIR_TEST/case4/cwd")
assert_finding "$out" "cc.sandbox.network_allowlist"

# Case 4b: network_allowlist_empty high when allowedDomains is empty.
mkdir -p "$TMPDIR_TEST/case4b/home/.claude"
cat > "$TMPDIR_TEST/case4b/home/.claude/settings.json" <<'EOF'
{"sandbox": {"enabled": true, "network": {"allowedDomains": []}}}
EOF
out=$(run_claude "$TMPDIR_TEST/case4b/home" "$TMPDIR_TEST/case4b/cwd")
assert_finding "$out" "cc.sandbox.network_allowlist_empty"

# Case 4c: legacy_schema critical when v0.1 field names are present.
mkdir -p "$TMPDIR_TEST/case4c/home/.claude"
cat > "$TMPDIR_TEST/case4c/home/.claude/settings.json" <<'EOF'
{"sandbox": {"enabled": true, "network": {"allowedHosts": ["github.com"]}}}
EOF
out=$(run_claude "$TMPDIR_TEST/case4c/home" "$TMPDIR_TEST/case4c/cwd")
assert_finding "$out" "cc.sandbox.legacy_schema"

# Case 5: deny_disable_flag high when sandbox enabled but deny missing the entry.
mkdir -p "$TMPDIR_TEST/case5/home/.claude"
echo '{"sandbox": {"enabled": true}, "permissions": {"deny": []}}' \
  > "$TMPDIR_TEST/case5/home/.claude/settings.json"
out=$(run_claude "$TMPDIR_TEST/case5/home" "$TMPDIR_TEST/case5/cwd")
assert_finding "$out" "cc.sandbox.deny_disable_flag"

# Case 6: no_wildcard_bash fires on Bash(*) and bare Bash, NOT on Bash(npm test:*).
mkdir -p "$TMPDIR_TEST/case6/home/.claude"
cat > "$TMPDIR_TEST/case6/home/.claude/settings.json" <<'EOF'
{"permissions": {"allow": ["Bash(*)", "Bash(npm test:*)", "Bash(wc:*)"]}}
EOF
out=$(run_claude "$TMPDIR_TEST/case6/home" "$TMPDIR_TEST/case6/cwd")
assert_finding "$out" "cc.permissions.no_wildcard_bash"

mkdir -p "$TMPDIR_TEST/case6b/home/.claude"
cat > "$TMPDIR_TEST/case6b/home/.claude/settings.json" <<'EOF'
{"permissions": {"allow": ["Bash(npm test:*)", "Bash(wc:*)"]}}
EOF
out=$(run_claude "$TMPDIR_TEST/case6b/home" "$TMPDIR_TEST/case6b/cwd")
assert_no_finding "$out" "cc.permissions.no_wildcard_bash"

# Case 7: mcp.project_auto_approve fires on enableAllProjectMcpServers=true.
mkdir -p "$TMPDIR_TEST/case7/home/.claude"
echo '{"enableAllProjectMcpServers": true}' \
  > "$TMPDIR_TEST/case7/home/.claude/settings.json"
out=$(run_claude "$TMPDIR_TEST/case7/home" "$TMPDIR_TEST/case7/cwd")
assert_finding "$out" "cc.mcp.project_auto_approve"

# Case 8: mcp.curated fires when an unknown MCP appears in ~/.claude.json.
mkdir -p "$TMPDIR_TEST/case8/home/.claude" "$TMPDIR_TEST/case8/home/.sandshell"
echo '["filesystem"]' > "$TMPDIR_TEST/case8/home/.sandshell/known-mcps.json"
cat > "$TMPDIR_TEST/case8/home/.claude.json" <<'EOF'
{"projects": {"/some/path": {"mcpServers": {"untrusted-mcp": {"command": "evil"}}}}}
EOF
out=$(run_claude "$TMPDIR_TEST/case8/home" "$TMPDIR_TEST/case8/cwd")
assert_finding "$out" "cc.mcp.curated"

echo "PASS: claude audit checks (sandbox, permissions, mcp)"
