#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/testlib.sh"

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/sandshell-test-detect.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

run_detect() {
  # Run detect.sh with an isolated HOME and cwd so the real user's settings
  # don't leak into the result.
  local home="$1" cwd="$2"
  mkdir -p "$home" "$cwd"
  (cd "$cwd" && HOME="$home" "$ROOT/scripts/detect.sh" 2>&1)
}

# Case 1: no settings anywhere → configured=false, default recommendation.
out=$(run_detect "$TMPDIR_TEST/case1/home" "$TMPDIR_TEST/case1/cwd")
[[ "$out" == *"cc_sandbox_configured=false"* ]] \
  || fail "case1: expected cc_sandbox_configured=false, got: $out"
[[ "$out" == *"setup-sandbox.sh personal"* ]] \
  || fail "case1: expected setup-sandbox.sh hint, got: $out"

# Case 2: sandbox block present with sandshell_managed marker but enabled is
# missing/false. This is the bug we dogfooded on 2026-04-20 — CC loads the
# config but enforces nothing. detect.sh must flag it, not report success.
mkdir -p "$TMPDIR_TEST/case2/home/.claude"
cat > "$TMPDIR_TEST/case2/home/.claude/settings.json" <<'EOF'
{
  "sandbox": {
    "filesystem": {"write": {"allowOnly": ["."], "denyWithinAllow": []}},
    "network": {"allowedHosts": []}
  },
  "sandshell_managed": true
}
EOF
out=$(run_detect "$TMPDIR_TEST/case2/home" "$TMPDIR_TEST/case2/cwd")
[[ "$out" == *"cc_sandbox_configured=false"* ]] \
  || fail "case2: present-but-disabled must report false, got: $out"
[[ "$out" == *"sandbox.enabled is not true"* ]] \
  || fail "case2: expected 'enabled' warning, got: $out"

# Case 3: sandbox.enabled=true → configured=true, no warning.
mkdir -p "$TMPDIR_TEST/case3/home/.claude"
cat > "$TMPDIR_TEST/case3/home/.claude/settings.json" <<'EOF'
{
  "sandbox": {
    "enabled": true,
    "filesystem": {"write": {"allowOnly": ["."], "denyWithinAllow": []}},
    "network": {"allowedHosts": []}
  },
  "sandshell_managed": true
}
EOF
out=$(run_detect "$TMPDIR_TEST/case3/home" "$TMPDIR_TEST/case3/cwd")
[[ "$out" == *"cc_sandbox_configured=true"* ]] \
  || fail "case3: enabled=true must report configured=true, got: $out"
[[ "$out" != *"sandbox.enabled is not true"* ]] \
  || fail "case3: should not emit the 'enabled' warning, got: $out"

# Case 4: project-level .claude/settings.json in cwd is honored.
mkdir -p "$TMPDIR_TEST/case4/cwd/.claude" "$TMPDIR_TEST/case4/home"
cat > "$TMPDIR_TEST/case4/cwd/.claude/settings.json" <<'EOF'
{
  "sandbox": {"enabled": true},
  "sandshell_managed": true
}
EOF
out=$(run_detect "$TMPDIR_TEST/case4/home" "$TMPDIR_TEST/case4/cwd")
[[ "$out" == *"cc_sandbox_configured=true"* ]] \
  || fail "case4: project settings with enabled=true must report true, got: $out"

echo "PASS: detect.sh reports sandbox status based on sandbox.enabled"
