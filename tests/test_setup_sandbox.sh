#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/testlib.sh"

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/sandshell-test-setup.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

mkdir -p "$TMPDIR_TEST/home"
export HOME="$TMPDIR_TEST/home"

set +e
output=$("$ROOT/scripts/setup-sandbox.sh" personal --profile=does-not-exist --show 2>&1)
status=$?
set -e

[[ "$status" -ne 0 ]] || fail "Expected setup-sandbox.sh to fail for an unknown profile"
[[ "$output" == *"ERROR: Unknown profile 'does-not-exist'"* ]] || fail "Unexpected output: $output"

echo "PASS: setup-sandbox profile validation"

# Regression: the `sandbox` block in CC settings.json is a no-op unless
# `sandbox.enabled == true`. A config without it is silently inert — exactly
# the failure we hit while dogfooding on 2026-04-20. Guard it here.
"$ROOT/scripts/setup-sandbox.sh" user --profile=default >/dev/null
SETTINGS_FILE="$TMPDIR_TEST/home/.claude/settings.json"
assert_json_value "$SETTINGS_FILE" "sandbox.enabled" "true"
assert_json_value "$SETTINGS_FILE" "sandshell_managed" "true"

echo "PASS: setup-sandbox emits sandbox.enabled=true on fresh install"

# And the merge path must preserve `enabled: true` even when an existing
# settings.json lacks it (e.g. upgrading from a pre-fix sandshell install).
mkdir -p "$TMPDIR_TEST/home2/.claude"
cat > "$TMPDIR_TEST/home2/.claude/settings.json" <<'EOF'
{
  "sandbox": {
    "filesystem": {"allowWrite": ["$TMPDIR"]}
  },
  "sandshell_managed": true
}
EOF
HOME="$TMPDIR_TEST/home2" "$ROOT/scripts/setup-sandbox.sh" user --profile=default >/dev/null
assert_json_value "$TMPDIR_TEST/home2/.claude/settings.json" "sandbox.enabled" "true"

echo "PASS: setup-sandbox merge sets sandbox.enabled=true on upgrade"
